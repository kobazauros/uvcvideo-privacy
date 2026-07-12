# SPDX-License-Identifier: GPL-2.0
obj-m += uvcvideo.o
uvcvideo-objs := uvc_driver.o uvc_queue.o uvc_v4l2.o uvc_video.o uvc_ctrl.o \
		 uvc_status.o uvc_isight.o uvc_debugfs.o uvc_metadata.o \
		 uvc_entity.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M="$(PWD)" modules

clean:
	$(MAKE) -C $(KDIR) M="$(PWD)" clean
