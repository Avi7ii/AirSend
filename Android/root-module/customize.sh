#!/system/bin/sh

ui_print "- Installing AirSend daemon"

if [ "$ARCH" != "arm64" ]; then
  abort "AirSend currently requires an arm64 device"
fi

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/supervisor.sh" 0 0 0755
set_perm "$MODPATH/system/bin/airsend_supervisor" 0 0 0755
set_perm "$MODPATH/system/bin/airsend_daemon" 0 0 0755
set_perm "$MODPATH/system/app/AirSend/AirSend.apk" 0 0 0644
