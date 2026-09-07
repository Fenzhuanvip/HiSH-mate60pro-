include ../utils/Makefrag

.ONESHELL:

export CFLAGS := $(CFLAGS) -fPIC

SOURCE_URL = https://cairographics.org/releases/pixman-0.42.2.tar.gz
SOURCE_FILE = pixman-0.42.2.tar.gz
SOURCE_DIR = pixman-0.42.2
CONFIG_ARGS = --host=$(OHOS_ARCH)-linux --prefix=$(PREFIX) --enable-static --disable-shared --disable-gtk --disable-libpng --disable-arm-neon --disable-arm-a64-neon

all: download/$(SOURCE_FILE)
	rm -rf temp build
	mkdir -p temp build
	cd temp && tar xvf ../download/$(SOURCE_FILE)
	cd temp/$(SOURCE_DIR) && ./configure $(CONFIG_ARGS)
	test -f temp/$(SOURCE_DIR)/config.h
	cd temp/$(SOURCE_DIR) && make -j $(shell nproc)
	cd temp/$(SOURCE_DIR) && make install DESTDIR=$(shell pwd)/build
	mkdir -p ../buildroot
	rm -fv build$(PREFIX)/lib/*.la
	find build -type f -exec file {} \; | grep ELF | awk '{print substr($$1, 0, length($$1)-1);}' | xargs -r -t $(OHOS_SDK_HOME)/native/llvm/bin/llvm-strip
	cp -rfv build$(PREFIX)/. ../buildroot | tee file.lst

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 $(SOURCE_URL)