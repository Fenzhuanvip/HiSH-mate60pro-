include ../utils/Makefrag

SOURCE_URL = https://cairographics.org/releases/pixman-0.42.2.tar.gz
SOURCE_FILE = pixman-0.42.2.tar.gz
SOURCE_DIR = pixman-0.42.2
CONFIG_ARGS = --host=$(OHOS_ARCH)-linux --prefix=$(PREFIX) --enable-static --disable-shared --disable-gtk --disable-libpng --disable-arm-neon --disable-arm-a64-neon
export CFLAGS := $(CFLAGS) -fPIC -I$(shell pwd)/temp/$(SOURCE_DIR)/$(BUILD_DIR)

$(eval $(call define_autotools_package))

configure:
	cd temp/$(SOURCE_DIR)/$(BUILD_DIR) && ../configure $(CONFIG_ARGS)
	cp -f temp/$(SOURCE_DIR)/$(BUILD_DIR)/config.h temp/$(SOURCE_DIR)/pixman/config.h
