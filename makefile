.PHONY: all clean tsan

all:
	@# Create build dir if it doesn't exist
	@mkdir -p build
	@echo "==> Configuring and Building for $$(uname -m)..."
	cd build && cmake .. && make -j$$(nproc)

tsan:
	@# Create build dir if it doesn't exist
	@mkdir -p build
	@echo "==> Configuring and Building with ThreadSanitizer (TSAN)..."
	cd build && cmake -DENABLE_TSAN=ON .. && make -j$$(nproc)

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf build