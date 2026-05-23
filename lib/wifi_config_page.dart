import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:wifi_scan/wifi_scan.dart';
import 'package:permission_handler/permission_handler.dart';
class WifiConfigPage extends StatefulWidget {
  const WifiConfigPage({super.key});

  @override
  State<WifiConfigPage> createState() => _WifiConfigPageState();
}

class _WifiConfigPageState extends State<WifiConfigPage> {
  final String databaseUrl =
      'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app';
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  List<WiFiAccessPoint> accessPoints = [];
  bool _isScanning = false;

  Future<void> _scanNetworks() async {
    setState(() => _isScanning = true);
    try {
      final can = await WiFiScan.instance.canGetScannedResults();
      if (can != CanGetScannedResults.yes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot scan Wi‑Fi. Make sure Location is ON and the app has location permission.'),
            ),
          );
        }
        setState(() => _isScanning = false);
        return;
      }
      final results = await WiFiScan.instance.getScannedResults();
      setState(() => accessPoints = results);
    } catch (e) {
      print('Scan error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan failed: $e')),
        );
      }
    }
    setState(() => _isScanning = false);
  }

  Future<void> _sendCredentials() async {
    final ssid = ssidController.text.trim();
    final password = passwordController.text.trim();
    if (ssid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter an SSID')));
      return;
    }
    try {
      await http.patch(
        Uri.parse('$databaseUrl/wifiConfig.json'),
        body: jsonEncode({'ssid': ssid, 'password': password}),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Credentials sent. ESP32 will reconnect.')),
      );
    } catch (e) {
      print('Error sending WiFi config: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send credentials')),
      );
    }
  }

  Future<void> _forgetNetwork() async {
    try {
      await http.patch(
        Uri.parse('$databaseUrl/wifiConfig.json'),
        body: jsonEncode({'command': 'forget'}),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Forget command sent. ESP32 will reboot into AP mode.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send forget command: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WiFi Settings (Online)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: ssidController,
              decoration: const InputDecoration(labelText: 'SSID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _sendCredentials,
              child: const Text('Send to ESP32'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _forgetNetwork,
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text('Forget Network & Reboot to AP'),
            ),
            const Divider(),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Nearby Networks',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _scanNetworks,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _isScanning
                ? const Center(child: CircularProgressIndicator())
                : Expanded(
              child: ListView.builder(
                itemCount: accessPoints.length,
                itemBuilder: (context, index) {
                  final ap = accessPoints[index];
                  return ListTile(
                    title: Text(ap.ssid),
                    trailing: Text('${ap.level} dBm'),
                    onTap: () => ssidController.text = ap.ssid,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}