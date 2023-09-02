import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_barrage/flutter_barrage.dart';
import 'package:get/get.dart';
import 'package:pure_live/common/index.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:media_kit/media_kit.dart'; // Provides [Player], [Media], [Playlist] etc.
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;
import 'package:window_manager/window_manager.dart';
import 'danmaku_text.dart';
import 'video_controller_panel.dart';

class VideoController with ChangeNotifier {
  final GlobalKey playerKey;
  final LiveRoom room;
  final String datasourceType;
  String datasource;
  final bool allowBackgroundPlay;
  final bool allowScreenKeepOn;
  final bool allowFullScreen;
  final bool fullScreenByDefault;
  final bool autoPlay;
  final videoFit = BoxFit.contain.obs;

  // Create a [Player] to control playback.
  late final player = Player();
  // Create a [VideoController] to handle video output from [Player].
  late final controller = media_kit_video.VideoController(player);
  VolumeController volumeController = VolumeController()..showSystemUI = false;
  ScreenBrightness brightnessController = ScreenBrightness();

  final hasError = false.obs;
  final isPlaying = false.obs;
  final isBuffering = false.obs;
  final isPipMode = false.obs;
  final isFullscreen = false.obs;
  final isWindowFullscreen = false.obs;
  bool get supportPip => Platform.isAndroid;
  bool get supportWindowFull => Platform.isWindows || Platform.isLinux;
  bool get fullscreenUI => isFullscreen.value || isWindowFullscreen.value;

  // Controller ui status
  Timer? showControllerTimer;
  final showController = true.obs;
  final showSettting = false.obs;
  final showLocked = false.obs;
  bool playBackisPlaying = false;
  void enableController() {
    showControllerTimer?.cancel();
    showControllerTimer = Timer(const Duration(seconds: 2), () {
      showController.value = false;
    });
    showController.value = true;
  }

  // Timed shutdown control
  final shutdownMinute = 0.obs;
  Timer? _shutdownTimer;
  void setShutdownTimer(int minutes) {
    showControllerTimer?.cancel();
    _shutdownTimer?.cancel();
    shutdownMinute.value = minutes;
    if (minutes == 0) return;
    _shutdownTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      shutdownMinute.value--;
      if (shutdownMinute.value == 0) exit(0);
    });
  }

  VideoController({
    required this.playerKey,
    required this.room,
    required this.datasourceType,
    required this.datasource,
    this.allowBackgroundPlay = false,
    this.allowScreenKeepOn = false,
    this.allowFullScreen = true,
    this.fullScreenByDefault = false,
    this.autoPlay = true,
    BoxFit fitMode = BoxFit.contain,
  }) {
    videoFit.value = fitMode;
    if (allowScreenKeepOn) WakelockPlus.enable();
    initVideoController();
    initDanmaku();
    initBattery();
  }

  // Battery level control
  final Battery _battery = Battery();
  final batteryLevel = 100.obs;
  void initBattery() {
    if (!Platform.isWindows) {
      _battery.batteryLevel.then((value) => batteryLevel.value = value);
      _battery.onBatteryStateChanged.listen((state) async {
        batteryLevel.value = await _battery.batteryLevel;
      });
    }
  }

  void initVideoController() {
    // fix auto fullscreen
    if (fullScreenByDefault && datasource.isNotEmpty) {
      Timer(const Duration(milliseconds: 500), () => toggleFullScreen());
    }
    setDataSource(datasource);
    player.stream.playing.listen(
      (bool playing) {
        if (playing) {
          isPlaying.value = true;
        } else {
          isPlaying.value = false;
        }
      },
    );
  }

  // Danmaku player control
  final danmakuController = BarrageWallController();
  final hideDanmaku = false.obs;
  final danmakuArea = 1.0.obs;
  final danmakuSpeed = 8.0.obs;
  final danmakuFontSize = 16.0.obs;
  final danmakuFontBorder = 0.5.obs;
  final danmakuOpacity = 1.0.obs;

  void initDanmaku() {
    hideDanmaku.value = PrefUtil.getBool('hideDanmaku') ?? false;
    hideDanmaku.listen((data) {
      PrefUtil.setBool('hideDanmaku', data);
    });
    danmakuArea.value = PrefUtil.getDouble('danmakuArea') ?? 1.0;
    danmakuArea.listen((data) {
      PrefUtil.setDouble('danmakuArea', data);
    });
    danmakuSpeed.value = PrefUtil.getDouble('danmakuSpeed') ?? 8;
    danmakuSpeed.listen((data) {
      PrefUtil.setDouble('danmakuSpeed', data);
    });
    danmakuFontSize.value = PrefUtil.getDouble('danmakuFontSize') ?? 16;
    danmakuFontSize.listen((data) {
      PrefUtil.setDouble('danmakuFontSize', data);
    });
    danmakuFontBorder.value = PrefUtil.getDouble('danmakuFontBorder') ?? 0.5;
    danmakuFontBorder.listen((data) {
      PrefUtil.setDouble('danmakuFontBorder', data);
    });
    danmakuOpacity.value = PrefUtil.getDouble('danmakuOpacity') ?? 1.0;
    danmakuOpacity.listen((data) {
      PrefUtil.setDouble('danmakuOpacity', data);
    });
  }

  void sendDanmaku(LiveMessage msg) {
    if (hideDanmaku.value) return;

    danmakuController.send([
      Bullet(
        child: DanmakuText(
          msg.message,
          fontSize: danmakuFontSize.value,
          strokeWidth: danmakuFontBorder.value,
          color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
        ),
      ),
    ]);
  }

  @override
  void dispose() {
    if (allowScreenKeepOn) WakelockPlus.disable();
    _shutdownTimer?.cancel();
    brightnessController.resetScreenBrightness();
    danmakuController.dispose();
    player.dispose();
    super.dispose();
  }

  void refresh() {
    setDataSource(datasource);
  }

  void setDataSource(String url) async {
    datasource = url;
    // fix datasource empty error
    if (datasource.isEmpty) {
      hasError.value = true;
      return;
    }
    final Media playable = Media(datasource);
    await player.open(playable);
  }

  void setVideoFit(BoxFit fit) {
    videoFit.value = fit;
    notifyListeners();
  }

  void togglePlayPause() {
    player.playOrPause();
  }

   void toggleFullScreen() {
    // disable locked
    showLocked.value = false;
    // fix danmaku overlap bug
    if (!hideDanmaku.value) {
      hideDanmaku.value = true;
      Timer(const Duration(milliseconds: 500), () {
        hideDanmaku.value = false;
      });
    }
    // fix obx setstate when build
    showControllerTimer?.cancel();
    Timer(const Duration(milliseconds: 500), () {
      enableController();
    });

    if (Platform.isWindows || Platform.isLinux) {
      if (!isFullscreen.value) {
        WindowManager.instance.setFullScreen(true);
        Get.to(() => DesktopFullscreen(controller: this));
      } else {
        WindowManager.instance.setFullScreen(false);
        Get.back();
        // 重设大小，修复窗口大小BUG
        WindowManager.instance.getSize().then((value) => WindowManager.instance
            .setSize(Size(value.width + 1, value.height + 1)));
      }
      isFullscreen.toggle();
    } else if (Platform.isAndroid || Platform.isIOS) {
      // mobileController?.toggleFullScreen();
      Timer(const Duration(milliseconds: 400), () {
        isFullscreen.toggle();
        // fix immersion status bar problem
        if (Platform.isAndroid) {
          SystemChrome.setEnabledSystemUIMode(!isFullscreen.value
              ? SystemUiMode.edgeToEdge
              : SystemUiMode.immersiveSticky);
        }
      });
    } else {
      throw UnimplementedError('Unsupported Platform');
    }
  }

  void toggleWindowFullScreen() {
    // disable locked
    showLocked.value = false;
    // fix danmaku overlap bug
    if (!hideDanmaku.value) {
      hideDanmaku.value = true;
      Timer(const Duration(milliseconds: 500), () {
        hideDanmaku.value = false;
      });
    }
    // fix obx setstate when build
    showControllerTimer?.cancel();
    Timer(const Duration(milliseconds: 500), () {
      enableController();
    });

    if (Platform.isWindows || Platform.isLinux) {
      if (!isWindowFullscreen.value) {
        Get.to(() => DesktopFullscreen(controller: this));
      } else {
        Get.back();
      }
      isWindowFullscreen.toggle();
    } else {
      throw UnimplementedError('Unsupported Platform');
    }
    enableController();
  }

  void enterPipMode(BuildContext context) async {}

  // volumn & brightness
  Future<double> volumn() async {
    return await volumeController.getVolume();
  }

  Future<double> brightness() async {
    if (Platform.isWindows || Platform.isLinux) {
      return await brightnessController.current;
    } else if (Platform.isAndroid || Platform.isIOS) {
      return await brightnessController.current;
    } else {
      throw UnimplementedError('Unsupported Platform');
    }
  }

  void setVolumn(double value) async {
    volumeController.setVolume(value);
  }

  void setBrightness(double value) async {
    if (Platform.isWindows || Platform.isLinux) {
      brightnessController.setScreenBrightness(value);
    } else if (Platform.isAndroid || Platform.isIOS) {
      brightnessController.setScreenBrightness(value);
    } else {
      throw UnimplementedError('Unsupported Platform');
    }
  }
}

// use fullscreen with controller provider
class MobileFullscreen extends StatefulWidget {
  const MobileFullscreen({
    Key? key,
    required this.controller,
  }) : super(key: key);

  final VideoController controller;

  @override
  State<MobileFullscreen> createState() => _MobileFullscreenState();
}

class _MobileFullscreenState extends State<MobileFullscreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.refresh();
    }
  }

  @override
  dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: WillPopScope(
        onWillPop: () {
          widget.controller.toggleFullScreen();
          return Future(() => true);
        },
        child: Container(
          alignment: Alignment.center,
          color: Colors.black,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoControllerPanel(controller: widget.controller),
            ],
          ),
        ),
      ),
    );
  }
}

class DesktopFullscreen extends StatelessWidget {
  const DesktopFullscreen({Key? key, required this.controller})
      : super(key: key);

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Obx(() => media_kit_video.Video(
                controller: controller.controller,
                fit: controller.videoFit.value,
              )),
          VideoControllerPanel(controller: controller),
        ],
      ),
    );
  }
}
