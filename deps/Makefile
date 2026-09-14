# TOOL_HOME must be set externally (HarmonyOS Commandline Tools)
ifndef TOOL_HOME
$(error TOOL_HOME is not set. Please download HarmonyOS Commandline Tools from https://developer.huawei.com/consumer/cn/download/ and set TOOL_HOME)
endif

# Set derived SDK paths
export DEVECO_SDK_HOME = $(TOOL_HOME)/sdk
export OHOS_SDK_HOME = $(TOOL_HOME)/sdk/default/openharmony

# Set default platform to x86_64 for emulator
OHOS_ARCH ?= x86_64
OHOS_ABI ?= x86_64

PKGS=zstd \
    zlib \
    pcre2 \
    libglib \
    pixman \
    libqemu
STAMP=$(patsubst %,%/.stamp,$(PKGS))

# Default target
all: copy

# Build for x86_64 platform
x86_64: clean_libqemu
	$(MAKE) copy OHOS_ARCH=x86_64 OHOS_ABI=x86_64

# Build for aarch64 platform
aarch64: clean_libqemu
	$(MAKE) copy OHOS_ARCH=aarch64 OHOS_ABI=arm64-v8a

clean_libqemu:
	rm -f libqemu/.stamp
	rm -rf libqemu/temp libqemu/build

copy: output/.stamp

output/.stamp: $(STAMP) Makefile
	mkdir -p ../feature/hish_main/libs/$(OHOS_ABI)
	rm -f ../feature/hish_main/libs/$(OHOS_ABI)/*
	cp output/*.so ../feature/hish_main/libs/$(OHOS_ABI)/
	cp output/*.so.* ../feature/hish_main/libs/$(OHOS_ABI)/
	set -e; \
	LIBDIR=../feature/hish_main/libs/$(OHOS_ABI); \
	BR=buildroot/lib; \
	if [ -e "$$BR/libpcre2-8.so.0" ]; then \
	  cp -L "$$BR/libpcre2-8.so.0" "$$LIBDIR/libpcre2-8.so.0"; \
	  cp -L "$$BR/libpcre2-8.so.0" "$$LIBDIR/libpcre2-8.so"; \
	elif [ -e "$$BR/libpcre2-8.so" ]; then \
	  cp -L "$$BR/libpcre2-8.so" "$$LIBDIR/libpcre2-8.so"; \
	  cp -L "$$BR/libpcre2-8.so" "$$LIBDIR/libpcre2-8.so.0"; \
	else \
	  echo "libpcre2-8.so not found in $$BR" >&2; \
	  ls -la "$$BR" || true; \
	  exit 1; \
	fi; \
	if [ -e "$$BR/libz.so" ]; then \
	  cp -L "$$BR/libz.so" "$$LIBDIR/libz.so"; \
	elif [ -e "$$BR/libz.so.1" ]; then \
	  cp -L "$$BR/libz.so.1" "$$LIBDIR/libz.so"; \
	else \
	  echo "libz.so not found in $$BR" >&2; \
	  ls -la "$$BR" || true; \
	  exit 1; \
	fi; \
	command -v patchelf >/dev/null 2>&1 || { echo "patchelf is required" >&2; exit 1; }; \
	if patchelf --print-needed $$LIBDIR/libqemu-system-aarch64.so | grep -qx libpcre2-8.so.0; then \
	  patchelf --replace-needed libpcre2-8.so.0 libpcre2-8.so $$LIBDIR/libqemu-system-aarch64.so; \
	fi; \
	if patchelf --print-needed $$LIBDIR/libqemu-system-aarch64.so | grep -qx libslirp.so.0; then \
	  patchelf --replace-needed libslirp.so.0 libslirp.so $$LIBDIR/libqemu-system-aarch64.so; \
	fi; \
	patchelf --set-soname libpcre2-8.so $$LIBDIR/libpcre2-8.so; \
	patchelf --set-soname libslirp.so $$LIBDIR/libslirp.so; \
	patchelf --set-soname libz.so $$LIBDIR/libz.so
	mkdir -p ../feature/hish_main/src/main/resources/rawfile/vm/keymaps
	cp output/en-us ../feature/hish_main/src/main/resources/rawfile/vm/keymaps/
	test -f ../feature/hish_main/libs/$(OHOS_ABI)/libqemu-system-aarch64.so
	test -f ../feature/hish_main/libs/$(OHOS_ABI)/libpcre2-8.so
	test -f ../feature/hish_main/libs/$(OHOS_ABI)/libz.so
	touch output/.stamp

%/.stamp: %/Makefile
	make -C $(patsubst %/.stamp,%,$@) OHOS_ARCH=$(OHOS_ARCH) OHOS_ABI=$(OHOS_ABI)
	touch $@

clean:
	rm -f $(STAMP)
	rm -rf buildroot
	rm -rf output
