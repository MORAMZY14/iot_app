import 'package:flutter/material.dart';
import 'package:wifi_iot/wifi_iot.dart';

class WifiSetupPage extends StatefulWidget {
  const WifiSetupPage({super.key});

  @override
  State<WifiSetupPage> createState() => _WifiSetupPageState();
}

class _WifiSetupPageState extends State<WifiSetupPage> {
  List<WifiNetwork> networks = [];

  final TextEditingController passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    scanWifi();
  }

  Future<void> scanWifi() async {
    final list = await WiFiForIoTPlugin.loadWifiList();

    setState(() {
      networks = list;
    });
  }

  Future<void> connectWifi(String ssid) async {
    await WiFiForIoTPlugin.connect(
      ssid,
      password: passwordController.text,
      security: NetworkSecurity.WPA,
      joinOnce: true,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Connected to $ssid'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi Setup'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: 'WiFi Password',
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: networks.length,
                itemBuilder: (context, index) {
                  final wifi = networks[index];

                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.wifi),
                      title: Text(wifi.ssid ?? ''),
                      onTap: () {
                        connectWifi(wifi.ssid ?? '');
                      },
                    ),
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
