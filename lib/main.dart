import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const BadgeNodeApp());
}

class BadgeNodeApp extends StatelessWidget {
  const BadgeNodeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BadgeNode Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const BadgeNodeHome(),
    );
  }
}

class BadgeNodeHome extends StatefulWidget {
  const BadgeNodeHome({Key? key}) : super(key: key);

  @override
  State<BadgeNodeHome> createState() => _BadgeNodeHomeState();
}

class _BadgeNodeHomeState extends State<BadgeNodeHome> {
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? characteristic;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<List<int>>? notificationSubscription;
  
  bool isScanning = false;
  bool isConnected = false;
  bool _isSending = false;
  List<String> logs = [];
  
  // Status tracking
  String currentSteps = "0";
  String currentMode = "COMPANY";
  String lastInfo = "No data yet";
  
  final String serviceUUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String characteristicUUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  
  // Controllers for badge update form
  final nameController = TextEditingController();
  final surnameController = TextEditingController();
  final roleController = TextEditingController();
  final companyController = TextEditingController();
  final qrLinkController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Set default values
    nameController.text = "Mario";
    surnameController.text = "Rossi";
    roleController.text = "Developer";
    companyController.text = "ACME Corp";
    qrLinkController.text = "https://linkedin.com/in/mariorossi";
  }

  @override
  void dispose() {
    connectionSubscription?.cancel();
    notificationSubscription?.cancel();
    nameController.dispose();
    surnameController.dispose();
    roleController.dispose();
    companyController.dispose();
    qrLinkController.dispose();
    super.dispose();
  }

  void addLog(String message) {
    setState(() {
      logs.insert(0, "${DateTime.now().toLocal().toString().substring(11, 19)} - $message");
      if (logs.length > 1000) logs.removeLast();
    });
    
    // Auto-parse status if possible
    if (message.contains("Steps:")) {
      final match = RegExp(r"Steps: (\d+)").firstMatch(message);
      if (match != null) setState(() => currentSteps = match.group(1)!);
    }
    if (message.contains("Showing")) {
      setState(() => currentMode = message.contains("STEPS") ? "STEPS" : "COMPANY");
    }
    if (message.contains("Now showing")) {
      setState(() => currentMode = message.contains("steps") ? "STEPS" : "COMPANY");
    }
  }

  Future<void> scanAndConnect() async {
    if (isScanning || isConnected) return;

    setState(() {
      isScanning = true;
      logs.clear();
    });
    addLog("Scanning for BadgeNode...");

    try {
      // Start scanning
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      // Listen for scan results
      StreamSubscription? scanSubscription;
      scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          // Try both platformName and advName for compatibility
          String deviceName = result.device.platformName;
          if (deviceName.isEmpty) {
            deviceName = result.advertisementData.advName;
          }
          
          if (deviceName == "BadgeNode") {
            addLog("Found BadgeNode!");
            
            // Critical: Stop scanning and cancel subscription immediately
            await FlutterBluePlus.stopScan();
            await scanSubscription?.cancel();
            scanSubscription = null;
            
            await connectToDevice(result.device);
            return;
          }
        }
      });

      // Wait for scan timeout
      await Future.delayed(const Duration(seconds: 4));
      // If we are still scanning (subscription not null), then we didn't find it
      if (scanSubscription != null) {
        await scanSubscription?.cancel();
        if (!isConnected) {
          addLog("BadgeNode not found. Make sure it's powered on.");
          setState(() => isScanning = false);
        }
      }
    } catch (e) {
      addLog("Error: $e");
      setState(() => isScanning = false);
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    // Safety: Cancel any existing subscriptions to prevent duplicates
    await connectionSubscription?.cancel();
    await notificationSubscription?.cancel();
    connectionSubscription = null;
    notificationSubscription = null;

    try {
      addLog("Connecting...");
      
      // Listen to connection state
      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          // Only trigger if we were previously connected
          if (isConnected) {
            setState(() {
              isConnected = false;
              connectedDevice = null;
              characteristic = null;
            });
            addLog("Disconnected");
            // Clean up subscriptions on disconnect
            connectionSubscription?.cancel();
            notificationSubscription?.cancel();
          }
        }
      });
      
      // Connect to device
      await device.connect(
        timeout: const Duration(seconds: 35),
        mtu: null,
        license: License.values.first,
      );
      
      setState(() {
        connectedDevice = device;
        isConnected = true;
        isScanning = false;
      });
      
      addLog("Connected!");

      // Request larger MTU to ensure data packets don't get fragmented
      try {
        addLog("Requesting MTU 256...");
        await device.requestMtu(256);
        addLog("MTU updated!");
      } catch (e) {
        addLog("MTU request failed: $e (Ignoring)");
      }
      
      // Discovery
      await Future.delayed(const Duration(milliseconds: 500));
      addLog("Discovering services...");
      List<BluetoothService> services = await device.discoverServices();
      
      for (BluetoothService service in services) {
        if (service.uuid.toString() == serviceUUID) {
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid.toString() == characteristicUUID) {
              characteristic = char;
              
              // Enable notifications
              await char.setNotifyValue(true);
              
              // Listen to notifications
              notificationSubscription = char.onValueReceived.listen((value) {
                String message = utf8.decode(value);
                addLog("← $message");
                
                // Parse BADGE_DATA response to pre-fill form fields
                if (message.startsWith("BADGE_DATA:")) {
                  final parts = message.substring("BADGE_DATA:".length).split(";");
                  if (mounted) {
                    setState(() {
                      if (parts.length > 0) nameController.text = parts[0].trim();
                      if (parts.length > 1) surnameController.text = parts[1].trim();
                      if (parts.length > 2) roleController.text = parts[2].trim();
                      if (parts.length > 3) companyController.text = parts[3].trim();
                      if (parts.length > 4) qrLinkController.text = parts[4].trim();
                    });
                    addLog("Badge fields loaded from device");
                  }
                }
                
                // Track last info for display
                if (message.contains("=== BADGE INFO")) {
                  setState(() => lastInfo = message);
                }
              });
              
              addLog("Ready to send commands!");
              
              // Initial sync: fetch badge data to pre-fill form, then info for status card
              await Future.delayed(const Duration(milliseconds: 500));
              await sendCommand('GET_BADGE', withoutResponse: false);
              await sendCommand('INFO', withoutResponse: false);
              
              return;
            }
          }
        }
      }
      
      addLog("Service/Characteristic not found!");
    } catch (e) {
      addLog("Connection error: $e");
      await connectionSubscription?.cancel();
      await notificationSubscription?.cancel();
      setState(() {
        isConnected = false;
        isScanning = false;
        connectedDevice = null;
        characteristic = null;
      });
    }
  }

  Future<void> disconnect() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      connectionSubscription?.cancel();
      notificationSubscription?.cancel();
      setState(() {
        connectedDevice = null;
        characteristic = null;
        isConnected = false;
      });
      addLog("Disconnected");
    }
  }

  Future<void> sendCommand(String command, {bool withoutResponse = false}) async {
    if (characteristic == null) {
      addLog("Not connected!");
      return;
    }

    if (_isSending) {
      addLog("Busy...");
      return;
    }

    setState(() => _isSending = true);

    try {
      addLog("TX: '$command' (${command.length} chars)");
      
      List<int> bytes = utf8.encode(command);
      addLog("Bytes: ${bytes.join(',')}");

      await characteristic!.write(
        bytes, 
        withoutResponse: withoutResponse,
        timeout: 15,
      );
      
      addLog("Done.");
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      addLog("Send error: $e");
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> updateBadge() async {
    addLog("Loading badge data...");
    String command = "${nameController.text};${surnameController.text};"
        "${roleController.text};${companyController.text};${qrLinkController.text}";
    await sendCommand(command);
  }

  void _copyLogs() {
    final String allLogs = logs.join('\n');
    Clipboard.setData(ClipboardData(text: allLogs)).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs copied to clipboard')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('🎫 BadgeNode Controller'),
        actions: [
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: disconnect,
              tooltip: 'Disconnect',
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Connection button
              if (!isConnected)
                SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: ElevatedButton.icon(
                    onPressed: isScanning ? null : scanAndConnect,
                    icon: isScanning
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(isScanning ? 'Scanning...' : 'Connect to BadgeNode'),
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),

              if (isConnected) ...[
                // Badge Status Card
                Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline, size: 20),
                            const SizedBox(width: 8),
                            const Text('Badge Status', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green[100],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text('Connected', style: TextStyle(color: Colors.green, fontSize: 12)),
                            ),
                          ],
                        ),
                        const Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Steps: $currentSteps', style: const TextStyle(fontSize: 14)),
                            Text('Mode: $currentMode', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(lastInfo.replaceAll('=== BADGE INFO ===\n', ''), 
                          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Main Controls
                const Text('Quick Commands', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isSending ? null : () => sendCommand('STEPS', withoutResponse: false),
                      icon: const Icon(Icons.directions_walk),
                      label: const Text('Get Steps'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isSending ? null : () => sendCommand('TOGGLE', withoutResponse: false),
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Toggle Display'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isSending ? null : () => sendCommand('RESET', withoutResponse: false),
                      icon: const Icon(Icons.restore),
                      label: const Text('Reset Steps'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isSending ? null : () => sendCommand('INFO', withoutResponse: false),
                      icon: const Icon(Icons.info_outline),
                      label: const Text('Refresh Info'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                const Text('Display Modes', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isSending ? null : () => sendCommand('SHOW_STEPS', withoutResponse: false),
                      icon: const Icon(Icons.show_chart),
                      label: const Text('Show Steps'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isSending ? null : () => sendCommand('SHOW_COMPANY', withoutResponse: false),
                      icon: const Icon(Icons.business),
                      label: const Text('Show Company'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),

                // Badge update form
                const Text(
                  'Update Badge Data',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: surnameController,
                  decoration: const InputDecoration(
                    labelText: 'Surname',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: roleController,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: companyController,
                  decoration: const InputDecoration(
                    labelText: 'Company',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: qrLinkController,
                  decoration: const InputDecoration(
                    labelText: 'QR Link',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _isSending ? null : updateBadge,
                    icon: const Icon(Icons.send),
                    label: const Text('Update Badge'),
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                
                const SizedBox(height: 24),
                const Divider(),
                
                // Logs section with fixed height
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Operation Logs',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    TextButton.icon(
                      onPressed: _copyLogs,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  height: 250, // Fixed height for logs within the scrollable view
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: logs.isEmpty
                      ? const Center(
                          child: Text(
                            'No logs yet',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : SelectionArea(
                          child: ListView.builder(
                            itemCount: logs.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: Text(
                                  logs[index],
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}