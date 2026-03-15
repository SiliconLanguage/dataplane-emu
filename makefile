.PHONY: all clean

all:
	@# Create build dir if it doesn't exist
	@mkdir -p build
	@echo "==> Configuring and Building for $$(uname -m)..."
	cd build && cmake .. && make -j$$(nproc)

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf build