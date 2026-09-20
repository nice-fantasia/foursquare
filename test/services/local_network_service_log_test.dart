import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/services/local_network_service.dart';

void main() {
  test('LAN host startup log includes the concrete server port', () {
    expect(
      formatLanServerStartedLog(4040),
      'Server running on port 4040',
    );
  });
}
