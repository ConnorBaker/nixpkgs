"""Resolve a Nix-packaged consumer's CUDA driver at its first request."""

import ctypes
import os


def load_driver(name="libcuda.so.1", mode=ctypes.DEFAULT_MODE):
    if name != "libcuda.so.1":
        return ctypes.CDLL(name, mode)
    if "@lookup@":
        lookup = getattr(ctypes.cdll["@lookup@"], "@symbol@")
        lookup.argtypes = (ctypes.c_char_p, ctypes.c_int)
        lookup.restype = ctypes.c_void_p
        handle = lookup(b"libcuda.so.1", mode | os.RTLD_NOW)
        if handle:
            return ctypes.CDLL(name, mode, handle=handle)
    try:
        return ctypes.CDLL(name, mode)
    except OSError:
        ctypes.CDLL("@host@", mode)
        return ctypes.CDLL(name, mode)
