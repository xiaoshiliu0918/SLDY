TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AwemeLitePlus

AwemeLitePlus_FILES = Hooks.m \
                      ACConfig.m \
                      ACUtils.m \
                      ACFloatingBall.m \
                      ACFullscreenController.m \
                      ACMediaSaver.m

AwemeLitePlus_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-function
# 排查问题时打开下面这行，ACLog 才会真正输出（默认编译期完全剔除）
# AwemeLitePlus_CFLAGS += -DAC_DEBUG_LOG=1
AwemeLitePlus_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/library.mk
