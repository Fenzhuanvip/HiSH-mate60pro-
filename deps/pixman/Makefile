include ../utils/Makefrag

export CFLAGS := $(CFLAGS) -fPIC

SOURCE_URL = https://cairographics.org/releases/pixman-0.42.2.tar.gz
SOURCE_FILE = pixman-0.42.2.tar.gz
SOURCE_DIR = pixman-0.42.2
CONFIG_ARGS = --host=$(OHOS_ARCH)-linux --prefix=$(PREFIX) --enable-static --disable-shared --disable-gtk --disable-libpng --disable-arm-neon --disable-arm-a64-neon

all: download/$(SOURCE_FILE)
	rm -rf temp build
	mkdir -p temp build
	tar xf download/$(SOURCE_FILE) -C temp
	cd temp/$(SOURCE_DIR) && ./configure $(CONFIG_ARGS)
	pwd
	ls -la temp/$(SOURCE_DIR) | head
	find temp/$(SOURCE_DIR) -name 'config.h*' -ls || true
	rm -f temp/$(SOURCE_DIR)/config.h temp/$(SOURCE_DIR)/pixman/config.h
	cd temp/$(SOURCE_DIR) && ./config.status config.h
	find temp/$(SOURCE_DIR) -name 'config.h*' -ls || true
	if [ -f temp/$(SOURCE_DIR)/config.h ]; then \
		cp -f temp/$(SOURCE_DIR)/config.h temp/$(SOURCE_DIR)/pixman/config.h; \
	elif [ -f temp/$(SOURCE_DIR)/pixman/config.h ]; then \
		cp -f temp/$(SOURCE_DIR)/pixman/config.h temp/$(SOURCE_DIR)/config.h; \
	else \
		echo "ERROR: pixman config.h missing after config.status"; \
		ls -la temp/$(SOURCE_DIR); \
		exit 1; \
	fi
	$(MAKE) -C temp/$(SOURCE_DIR) -j $(shell nproc)
	$(MAKE) -C temp/$(SOURCE_DIR) install DESTDIR=$(CURDIR)/build
	mkdir -p ../buildroot
	rm -fv build$(PREFIX)/lib/*.la
	find build -type f -exec file {} \; | grep ELF | awk '{print substr($$1, 0, length($$1)-1);}' | xargs -r -t $(OHOS_SDK_HOME)/native/llvm/bin/llvm-strip
	cp -rfv build$(PREFIX)/. ../buildroot | tee file.lst

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 $(SOURCE_URL)
