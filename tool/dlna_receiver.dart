// 最小 DLNA 媒体接收器，仅用于真机联调投屏链路。
//
// 运行：dart run tool/dlna_receiver.dart
// 然后手机 App 播放页点「投屏」，选择本机设备名。脚本会打印收到的
// SetAVTransportURI / Play / Seek / Stop，并在 Play 时实际拉取 1KB
// 视频流，验证手机侧转发代理可达且支持 Range。
//
// 不做视频渲染：它只验证「发现 → 控制 → 拉流」三段链路是否打通。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dlna_receiver_util.dart';

const String _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
const String _rendering =
    'urn:schemas-upnp-org:service:RenderingControl:1';
const String _rendererType =
    'urn:schemas-upnp-org:device:MediaRenderer:1';

Future<void> main(List<String> args) async {
  final String name = argValue(args, '--name') ?? 'ApexDrama Test Renderer (PC)';
  final String? host = await lanAddress();
  if (host == null) {
    stderr.writeln('未找到局域网 IPv4 地址，请先连接 Wi-Fi / 有线网络。');
    exitCode = 1;
    return;
  }
  final _Receiver receiver = _Receiver(name: name, host: host);
  try {
    await receiver.start();
  } catch (error) {
    stderr.writeln('启动失败：$error');
    exitCode = 1;
    return;
  }
  // HTTP / UDP 监听会保持事件循环；主函数返回后继续服务，Ctrl+C 退出。
  print('按 Ctrl+C 退出。');
}

class _Receiver {
  _Receiver({required this.name, required this.host});

  final String name;
  final String host;

  HttpServer? _http;
  RawDatagramSocket? _ssdp;
  String _uri = '';
  String _state = 'STOPPED';
  Duration _base = Duration.zero;
  final Stopwatch _clock = Stopwatch();

  Duration get _position => _base + _clock.elapsed;

  Future<void> start() async {
    final HttpServer http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _http = http;
    http.listen((HttpRequest request) => unawaited(_handleHttp(request)));

    final RawDatagramSocket ssdp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      1900,
      reuseAddress: true,
    );
    _ssdp = ssdp;
    try {
      ssdp.joinMulticast(InternetAddress('239.255.255.250'));
    } catch (_) {
      // 部分系统不允许加入组播；绑定 1900 通常仍能收到 M-SEARCH。
    }
    ssdp.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        _handleSsdp(ssdp.receive());
      }
    });

    print('DLNA 测试接收器已启动');
    print('  设备名：$name');
    print('  描述：  http://$host:${http.port}/desc.xml');
    print('  手机与电脑需在同一 Wi-Fi；Windows 防火墙弹窗请选择「允许」。');
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _ssdp?.close();
    _http = null;
    _ssdp = null;
  }

  void _handleSsdp(Datagram? datagram) {
    if (datagram == null) {
      return;
    }
    final String request = utf8.decode(
      datagram.data,
      allowMalformed: true,
    );
    if (!request.startsWith('M-SEARCH')) {
      return;
    }
    final String target = dlnaHeader(request, 'st') ?? '';
    if (!target.contains('MediaRenderer') && target != 'ssdp:all') {
      return;
    }
    final String response =
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'EXT:\r\n'
        'LOCATION: http://$host:${_http!.port}/desc.xml\r\n'
        'SERVER: Dart/1.0 UPnP/1.1 ApexDramaTest/1.0\r\n'
        'ST: $_rendererType\r\n'
        'USN: uuid:apex-drama-test::$target\r\n'
        '\r\n';
    _ssdp?.send(utf8.encode(response), datagram.address, datagram.port);
    print('[SSDP] 已响应 ${datagram.address.address} 的搜索请求');
  }

  Future<void> _handleHttp(HttpRequest request) async {
    switch (request.uri.path) {
      case '/desc.xml':
        await _xml(request.response, _description());
      case '/ctl/avt':
        await _soap(request, _avTransport);
      case '/ctl/rc':
        await _soap(request, _rendering);
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  }

  Future<void> _soap(HttpRequest request, String service) async {
    final String action = (request.headers.value('soapaction') ?? '')
        .split('#')
        .last
        .replaceAll('"', '')
        .trim();
    final String body = await utf8.decoder.bind(request).join();
    await _xml(request.response, _response(service, action, body));
  }

  String _response(String service, String action, String body) {
    final String inner;
    switch (action) {
      case 'SetAVTransportURI':
        _uri = dlnaTag(body, 'CurrentURI');
        _base = Duration.zero;
        _clock
          ..stop()
          ..reset();
        _state = 'STOPPED';
        print('[控制] SetAVTransportURI uri=$_uri');
        inner = '';
      case 'Play':
        _state = 'PLAYING';
        _clock.start();
        print('[控制] Play');
        unawaited(_probe(_uri));
        inner = '';
      case 'Pause':
        _base = _position;
        _clock
          ..stop()
          ..reset();
        _state = 'PAUSED_PLAYBACK';
        print('[控制] Pause @ ${formatDlnaTime(_base)}');
        inner = '';
      case 'Stop':
        _state = 'STOPPED';
        _base = Duration.zero;
        _clock
          ..stop()
          ..reset();
        print('[控制] Stop');
        inner = '';
      case 'Seek':
        _base = parseDlnaTime(dlnaTag(body, 'Target')) ?? Duration.zero;
        _clock
          ..stop()
          ..reset();
        if (_state == 'PLAYING') {
          _clock.start();
        }
        print('[控制] Seek -> ${formatDlnaTime(_base)}');
        inner = '';
      case 'GetTransportInfo':
        inner =
            '<CurrentTransportState>$_state</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus>'
            '<CurrentSpeed>1</CurrentSpeed>';
      case 'GetPositionInfo':
        inner =
            '<Track>1</Track>'
            '<TrackDuration>00:10:00</TrackDuration>'
            '<TrackMetaData></TrackMetaData>'
            '<TrackURI>${escapeXml(_uri)}</TrackURI>'
            '<RelTime>${formatDlnaTime(_position)}</RelTime>'
            '<AbsTime>${formatDlnaTime(_position)}</AbsTime>'
            '<RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>';
      case 'GetVolume':
        inner = '<CurrentVolume>50</CurrentVolume>';
      default:
        inner = '';
    }
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:${action}Response xmlns:u="$service">$inner'
        '</u:${action}Response></s:Body></s:Envelope>';
  }

  /// 真的向手机侧转发地址取 1KB，验证可达性与 Range。
  Future<void> _probe(String url) async {
    if (url.isEmpty) {
      return;
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final HttpClientResponse response = await request.close();
      final int bytes = await response.fold<int>(
        0,
        (int total, List<int> chunk) => total + chunk.length,
      );
      final String range = response.headers.value('content-range') ?? '-';
      print(
        '[拉流验证] ${response.statusCode} '
        '${response.headers.contentType} ${bytes}B range=$range',
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        print('[拉流验证] 状态异常，请检查手机端转发 / CDN');
      }
    } catch (error) {
      print('[拉流验证] 失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  String _description() {
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<root xmlns="urn:schemas-upnp-org:device-1-0">'
        '<specVersion><major>1</major><minor>0</minor></specVersion>'
        '<device>'
        '<deviceType>$_rendererType</deviceType>'
        '<friendlyName>${escapeXml(name)}</friendlyName>'
        '<manufacturer>ApexDrama</manufacturer>'
        '<modelName>Dart Test Renderer</modelName>'
        '<UDN>uuid:apex-drama-test</UDN>'
        '<serviceList>'
        '<service><serviceType>$_avTransport</serviceType>'
        '<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>'
        '<controlURL>/ctl/avt</controlURL></service>'
        '<service><serviceType>$_rendering</serviceType>'
        '<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>'
        '<controlURL>/ctl/rc</controlURL></service>'
        '</serviceList></device></root>';
  }

  Future<void> _xml(HttpResponse response, String body) async {
    response.headers.contentType = ContentType(
      'text',
      'xml',
      charset: 'utf-8',
    );
    response.write(body);
    await response.close();
  }
}
