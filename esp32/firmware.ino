#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <LittleFS.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <GxEPD2_3C.h>
#include <U8g2_for_Adafruit_GFX.h>
#include <QRCodeGFX.h>
#include <Preferences.h>

// --- PIN CONFIGURATION ---
#define EPD_CS      7
#define EPD_DC      1
#define EPD_RST     2
#define EPD_BUSY    10
#define I2C_SDA     8
#define I2C_SCL     9

// --- BLE UUIDs ---
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

// --- GLOBAL OBJECTS ---
BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;

GxEPD2_3C<GxEPD2_290_C90c, GxEPD2_290_C90c::HEIGHT> display(
  GxEPD2_290_C90c(EPD_CS, EPD_DC, EPD_RST, EPD_BUSY)
);
U8G2_FOR_ADAFRUIT_GFX u8g2;
QRCodeGFX qrcode(display);
Adafruit_MPU6050 mpu;
Preferences prefs;

// --- DATA STRUCTURES ---
struct BadgeData {
  String name = "Codemotion";
  String surname = "Milan 2025";
  String role = "Attendee";
  String company = "Community";
  String qrLink = "https://codemotion.com";
};

BadgeData badge;
int stepCount = 0;
bool showSteps = false;  // false = mostra company, true = mostra passi

// --- STEP COUNTER VARIABLES ---
float lastAccelMagnitude = 0;
unsigned long lastStepTime = 0;
const float STEP_THRESHOLD = 1.5;
const unsigned long STEP_MIN_DELAY = 250;

// --- STORAGE FUNCTIONS ---
void loadData() {
  prefs.begin("badge", false);
  
  stepCount = prefs.getInt("steps", 0);
  showSteps = prefs.getBool("showSteps", false);
  
  badge.name = prefs.getString("name", "Codemotion");
  badge.surname = prefs.getString("surname", "Milan 2025");
  badge.role = prefs.getString("role", "Attendee");
  badge.company = prefs.getString("company", "Community");
  badge.qrLink = prefs.getString("qrLink", "https://codemotion.com");
  
  prefs.end();
  
  sendBLE("Data loaded: " + String(stepCount) + " steps");
}

void saveStepCount() {
  prefs.begin("badge", false);
  prefs.putInt("steps", stepCount);
  prefs.end();
}

void saveShowSteps() {
  prefs.begin("badge", false);
  prefs.putBool("showSteps", showSteps);
  prefs.end();
}

void saveBadgeData() {
  prefs.begin("badge", false);
  prefs.putString("name", badge.name);
  prefs.putString("surname", badge.surname);
  prefs.putString("role", badge.role);
  prefs.putString("company", badge.company);
  prefs.putString("qrLink", badge.qrLink);
  prefs.end();
}

// --- STEP DETECTION ---
void detectStep() {
  if (!mpu.begin()) return;
  
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);
  
  float ax = a.acceleration.x;
  float ay = a.acceleration.y;
  float az = a.acceleration.z;
  
  float accelMagnitude = sqrt(ax*ax + ay*ay + az*az);
  float accelDiff = abs(accelMagnitude - lastAccelMagnitude);
  
  unsigned long currentTime = millis();
  
  if (accelDiff > STEP_THRESHOLD && 
      (currentTime - lastStepTime) > STEP_MIN_DELAY) {
    
    stepCount++;
    lastStepTime = currentTime;
    
    if (stepCount % 10 == 0) {
      saveStepCount();
    }
    
    if (stepCount % 50 == 0) {
      updateDisplay();
    }
    
    sendBLE("Step detected! Total: " + String(stepCount));
  }
  
  lastAccelMagnitude = accelMagnitude;
}

// --- DISPLAY FUNCTIONS ---
void updateDisplay() {
  display.setRotation(3);
  display.setFullWindow();
  display.firstPage();
  
  do {
    display.fillScreen(GxEPD_WHITE);
    
    u8g2.setBackgroundColor(GxEPD_WHITE);
    u8g2.setForegroundColor(GxEPD_BLACK);
    
    int x_margin = 5;
    int y_cursor = 0;

    // NAME
    u8g2.setFont(u8g2_font_crox5tb_tf);
    y_cursor += u8g2.getFontAscent() + 10; 
    u8g2.setCursor(x_margin, y_cursor);
    u8g2.print(badge.name);
    
    // SURNAME
    y_cursor += u8g2.getFontAscent() + 10;
    u8g2.setCursor(x_margin, y_cursor);
    u8g2.print(badge.surname);

    // ROLE
    u8g2.setFont(u8g2_font_luBIS10_tf);
    y_cursor += u8g2.getFontAscent() + 35;
    u8g2.setCursor(x_margin, y_cursor);
    u8g2.print(badge.role);

    // COMPANY or STEPS (in rosso)
    u8g2.setForegroundColor(GxEPD_RED);
    u8g2.setFont(u8g2_font_helvB18_tf);
    y_cursor += u8g2.getFontAscent() + 5;
    u8g2.setCursor(x_margin, y_cursor);
    
    if (showSteps) {
      u8g2.print(String(stepCount) + " steps");
    } else {
      u8g2.print(badge.company);
    }

    // QR CODE
    qrcode.generateData(badge.qrLink);
    qrcode.setScale(3);
    int qrSize = qrcode.getSideLength();
    int qrX = display.width() - qrSize;
    qrcode.draw(qrX, 0);
    
  } while (display.nextPage());
  
  display.hibernate();
  
  sendBLE("Display updated");
}

// --- BLE FUNCTIONS ---
void sendBLE(String msg) {
  if (deviceConnected && pCharacteristic) {
    pCharacteristic->setValue(msg.c_str());
    pCharacteristic->notify();
  }
  Serial.println(msg);
}

// Helper to extract data from the semicolon-separated string
String getValue(String data, char separator, int index) {
  int found = 0;
  int strIndex[] = {0, -1};
  int maxIndex = data.length() - 1;

  for (int i = 0; i <= maxIndex && found <= index; i++) {
    if (data.charAt(i) == separator || i == maxIndex) {
      found++;
      strIndex[0] = strIndex[1] + 1;
      strIndex[1] = (i == maxIndex) ? i + 1 : i;
    }
  }
  String val = (found > index) ? data.substring(strIndex[0], strIndex[1]) : "";
  val.trim();
  return val;
}

void handleCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return;

  Serial.print("Raw command received: [");
  Serial.print(cmd);
  Serial.println("]");

  // UPDATE BADGE DATA: Name;Surname;Role;Company;QRLink
  // Check if it contains at least 2 semicolons to avoid misinterpreting other commands
  int firstSemi = cmd.indexOf(';');
  int lastSemi = cmd.lastIndexOf(';');
  
  if (firstSemi != -1 && firstSemi != lastSemi) {
    sendBLE("Updating badge...");
    badge.name    = getValue(cmd, ';', 0);
    badge.surname = getValue(cmd, ';', 1);
    badge.role    = getValue(cmd, ';', 2);
    badge.company = getValue(cmd, ';', 3);
    badge.qrLink  = getValue(cmd, ';', 4);
    
    if (badge.qrLink == "") badge.qrLink = "https://codemotion.com";
    
    saveBadgeData();
    updateDisplay();
    sendBLE("Badge updated: " + badge.name + " " + badge.surname);
    return;
  }
  
  // SANITIZE: Remove trailing semicolon for simple commands if present
  if (cmd.endsWith(";")) {
    cmd = cmd.substring(0, cmd.length() - 1);
    cmd.trim();
  }
  
  Serial.print("Processing as simple command: ");
  Serial.println(cmd);
  
  // GET STEPS
  if (cmd == "STEPS") {
    Serial.println("Action: Sending steps");
    sendBLE("Steps: " + String(stepCount));
    return;
  }
  
  // RESET STEPS
  if (cmd == "RESET") {
    stepCount = 0;
    saveStepCount();
    updateDisplay();
    sendBLE("Steps reset to 0");
    return;
  }
  
  // TOGGLE DISPLAY MODE
  if (cmd == "TOGGLE") {
    Serial.println("Action: Toggling display mode");
    showSteps = !showSteps;
    saveShowSteps();
    updateDisplay();
    sendBLE(showSteps ? "Showing STEPS" : "Showing COMPANY");
    return;
  }
  
  // SHOW STEPS
  if (cmd == "SHOW_STEPS") {
    Serial.println("Action: Force show steps");
    showSteps = true;
    saveShowSteps();
    updateDisplay();
    sendBLE("Now showing steps");
    return;
  }
  
  // SHOW COMPANY
  if (cmd == "SHOW_COMPANY") {
    Serial.println("Action: Force show company");
    showSteps = false;
    saveShowSteps();
    updateDisplay();
    sendBLE("Now showing company");
    return;
  }
  
  // INFO
  if (cmd == "INFO") {
    Serial.println("Action: Sending device info");
    String info = "=== BADGE INFO ===\n";
    info += "Steps: " + String(stepCount) + "\n";
    info += "Mode: " + String(showSteps ? "STEPS" : "COMPANY") + "\n";
    info += "Name: " + badge.name + " " + badge.surname + "\n";
    info += "Company: " + badge.company + "\n";
    info += "Uptime: " + String(millis()/1000) + "s";
    sendBLE(info);
    return;
  }

  // GET_BADGE - returns raw badge fields for Flutter to pre-fill form
  if (cmd == "GET_BADGE") {
    Serial.println("Action: Sending badge data");
    String data = "BADGE_DATA:";
    data += badge.name + ";";
    data += badge.surname + ";";
    data += badge.role + ";";
    data += badge.company + ";";
    data += badge.qrLink;
    sendBLE(data);
    return;
  }
  
  // HELP
  sendBLE("Commands:\n"
          "STEPS - Get step count\n"
          "RESET - Reset steps to 0\n"
          "TOGGLE - Toggle steps/company\n"
          "SHOW_STEPS - Show steps\n"
          "SHOW_COMPANY - Show company\n"
          "INFO - System info\n"
          "Name;Surname;Role;Company;URL - Update badge");
}

// --- BLE CALLBACKS ---
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      sendBLE("Connected!");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("Disconnected");
    }
};

class MyCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      String value = pCharacteristic->getValue();
      if (value.length() > 0) {
        handleCommand(value);
      }
    }
};

// --- SETUP ---
void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("\n=== BADGE NODE STARTING ===");
  
  // Init I2C
  Wire.begin(I2C_SDA, I2C_SCL);
  
  // Init MPU6050
  Serial.println("Init MPU6050...");
  if (mpu.begin()) {
    mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    Serial.println("MPU6050 OK");
  } else {
    Serial.println("MPU6050 FAILED");
  }
  
  // Init Display
  Serial.println("Init display...");
  display.init(115200, true, 50, false);
  u8g2.begin(display);
  Serial.println("Display OK");
  
  // Load saved data
  Serial.println("Loading data...");
  loadData();
  
  // Init BLE
  Serial.println("Init BLE...");
  BLEDevice::init("BadgeNode");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_WRITE  |
                      BLECharacteristic::PROPERTY_NOTIFY
                    );

  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setCallbacks(new MyCallbacks());
  pCharacteristic->setValue("BadgeNode Ready");

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();
  
  Serial.println("BLE OK - BadgeNode");
  
  // Initial display
  updateDisplay();
  
  Serial.println("=== SYSTEM READY ===");
  sendBLE("System ready! " + String(stepCount) + " steps");
}

// --- LOOP ---
void loop() {
  // Detect steps
  detectStep();
  
  delay(50);
}
