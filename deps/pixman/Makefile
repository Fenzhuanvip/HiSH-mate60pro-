include ../utils/Makefrag

export CFLAGS := $(CFLAGS) -fPIC

SOURCE_URL = https://cairographics.org/releases/pixman-0.42.2.tar.gz
SOURCE_FILE = pixman-0.42.2.tar.gz
SOURCE_DIR = pixman-0.42.2

all: download/$(SOURCE_FILE)
	rm -rf temp build
	mkdir -p temp build
	tar xf download/$(SOURCE_FILE) -C temp
	cd temp/$(SOURCE_DIR) && rm -f cross.txt
	cd temp/$(SOURCE_DIR) && echo "[binaries]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "c = '${OHOS_SDK_HOME}/native/llvm/bin/$(OHOS_ARCH)-unknown-linux-ohos-clang'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpp = '${OHOS_SDK_HOME}/native/llvm/bin/$(OHOS_ARCH)-unknown-linux-ohos-clang++'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ar = '${OHOS_SDK_HOME}/native/llvm/bin/llvm-ar'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ld = '${OHOS_SDK_HOME}/native/llvm/bin/ld.lld'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "strip = '${OHOS_SDK_HOME}/native/llvm/bin/llvm-strip'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[host_machine]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "system = 'linux'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu_family = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "endian = 'little'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[properties]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "needs_exe_wrapper = true" >> cross.txt
	cd temp/$(SOURCE_DIR) && PKG_CONFIG=$(shell which pkg-config) PKG_CONFIG_LIBDIR=$(shell pwd)/../buildroot/lib/pkgconfig meson setup --cross-file cross.txt --prefix=$(PREFIX) --default-library=static -Dgtk=disabled -Dlibpng=disabled -Dtests=disabled -Dneon=disabled -Da64-neon=disabled build
	cd temp/$(SOURCE_DIR)/build && meson compile
	mkdir -p ../buildroot
	cd temp/$(SOURCE_DIR)/build && DESTDIR=$(CURDIR)/build meson install
	rm -fv build$(PREFIX)/lib/*.la
	find build -type f -exec file {} \; | grep ELF | awk '{print substr($$1, 0, length($$1)-1);}' | xargs -r -t $(OHOS_SDK_HOME)/native/llvm/bin/llvm-strip
	cp -rfv build$(PREFIX)/. ../buildroot | tee file.lst

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 $(SOURCE_URL)
