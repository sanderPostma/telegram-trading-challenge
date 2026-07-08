import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  test('parses WEEX book ticker midpoint price', () {
    final price = parseWeexBookTickerPrice(
      '{"symbol":"BTCUSDT","bidPrice":"62143.58","bidQty":"1.857620","askPrice":"62143.61","askQty":"0.050975"}',
    );

    expect(price, 62143.595);
  });

  test('parses WEEX 24hr ticker last price', () {
    final price = parseWeexTickerPrice(
      '{"symbol":"BTCUSDT","lastPrice":"62143.60"}',
    );

    expect(price, 62143.60);
  });

  test('parses WEEX mark price kline close prices', () {
    final candles = parseWeexKlines(
      '[["1783524600000","61620.9","61779.1","61567.4","61599.9","0","1783525500000","0",0,"0","0"]]',
    );

    expect(candles.single.timestampMs, 1783524600000);
    expect(candles.single.close, 61599.9);
  });
}
