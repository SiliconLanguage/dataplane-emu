#pragma once

// We don't include the backend header directly here to avoid circular dependencies,
// we just use a void pointer or forward declaration for the FUSE entry point.
int run_fuse_interceptor(int argc, char *argv[], void* backend_instance);