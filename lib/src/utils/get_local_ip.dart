import 'dart:io';

Future<String> getLocalIp() async {
  for (final interface in await NetworkInterface.list()) {
    for (final addr in interface.addresses) {
      if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
        return addr.address;
      }
    }
  }
  return 'localhost';
}
