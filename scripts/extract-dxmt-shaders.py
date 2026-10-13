#!/usr/bin/env python3
"""Recover unchanged generated shader arrays from the pinned public DXMT v0.80.

No executable is loaded or changed. Symbols, section bounds, length globals and
independent array SHA-256 pins all agree before writing C headers. Corresponding
shader source is retained in DXMT. To regenerate with Apple's Metal toolchain,
use unmodified upstream metalir_generator/metallib_generator/xxd definitions
(meson.build; src/{airconv,dxmt}/meson.build) without retained_shader_inputs.
"""
import hashlib
import pathlib
import struct
import sys

BINARIES = {
    'x86_64-windows/d3d11.dll': '7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47',
    'i386-windows/d3d11.dll': '9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d',
    'x86_64-unix/winemetal.so': '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca',
}
ARRAYS = {
    'dxmt_command': (152339, '875e4990dcd818c6f4b5dfb697823afd0d2b851601f0b1e89ec0e5dd54bbf195'),
    'air_msad': (5152, 'fda73b9a7a91b11060737fd372678d18123f59142a22dd6f6ba2c5d36ffc3962'),
    'air_samplepos': (3488, '0abefdee437628a5bdd26be6ebf1b099ec7c546260b3c937e9ddc40bd4287e80'),
    'air_tessellation': (59536, '21eca32c2172d6434ece59c11a5375fd8195a6285779855ae9dac2a4d1f7c811'),
}

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def array(blob, symbols, name):
    start, end = symbols[name]
    length_at, length_end = symbols[name + '_len']
    require(0 <= length_at <= length_end - 4 <= len(blob) - 4, 'Invalid shader length section')
    length = struct.unpack_from('<I', blob, length_at)[0]
    require(0 <= start <= start + length <= end <= len(blob), 'Invalid shader data section')
    data = blob[start:start + length]
    if name == 'dxmt_command':
        require(data[:4] == b'MTLB' and struct.unpack_from('<Q', data, 16)[0] == length, 'Invalid Metal library container')
    else:
        require(data[:4] == bytes.fromhex('dec0170b'), 'Invalid AIR bitcode wrapper')
        bitcode_offset, bitcode_size = struct.unpack_from('<II', data, 8)
        require(bitcode_offset >= 20 and bitcode_offset + bitcode_size <= length and
                data[bitcode_offset:bitcode_offset + 4] == bytes.fromhex('4243c0de'), 'Invalid AIR bitcode bounds/magic')
    expected_length, digest = ARRAYS[name]
    require(length == expected_length and hashlib.sha256(data).hexdigest() == digest, 'Shader array pin mismatch: ' + name)
    return data

def pe_symbols(blob):
    pe = struct.unpack_from('<I', blob, 60)[0]
    require(blob[:2] == b'MZ' and blob[pe:pe + 4] == b'PE\0\0', 'Invalid PE input')
    sections = struct.unpack_from('<H', blob, pe + 6)[0]
    section_start = pe + 24 + struct.unpack_from('<H', blob, pe + 20)[0]
    offset, count = struct.unpack_from('<II', blob, pe + 12)
    strings = offset + count * 18
    symbols = {}
    i = 0
    while i < count:
        entry = blob[offset + i * 18:offset + (i + 1) * 18]
        raw = entry[:8]
        if raw[:4] == bytes(4):
            start = strings + struct.unpack_from('<I', raw, 4)[0]
            name = blob[start:blob.index(0, start)].decode()
        else:
            name = raw.rstrip(b'\0').decode()
        name = name.lstrip('_')
        if name in ('dxmt_command', 'dxmt_command_len'):
            value, section = struct.unpack_from('<Ih', entry, 8)
            require(1 <= section <= sections and name not in symbols, 'Invalid/duplicate shader symbol')
            size, raw_offset = struct.unpack_from('<II', blob, section_start + (section - 1) * 40 + 16)
            require(value < size, 'Shader symbol outside PE section')
            symbols[name] = (raw_offset + value, raw_offset + size)
        i += 1 + entry[17]
    return symbols

def macho_symbols(blob):
    require(struct.unpack_from('<II', blob) == (0xfeedfacf, 0x01000007), 'Expected x86_64 Mach-O')
    count = struct.unpack_from('<I', blob, 16)[0]
    position = 32
    sections = []
    symtab = None
    for _ in range(count):
        command, size = struct.unpack_from('<II', blob, position)
        require(size >= 8 and position + size <= len(blob), 'Invalid Mach-O command')
        if command == 0x19:
            section_count = struct.unpack_from('<I', blob, position + 64)[0]
            require(72 + section_count * 80 <= size, 'Invalid Mach-O section count')
            for i in range(section_count):
                sections.append(struct.unpack_from('<QQI', blob, position + 72 + i * 80 + 32))
        elif command == 2:
            require(symtab is None, 'Duplicate Mach-O symbol table')
            symtab = struct.unpack_from('<IIII', blob, position + 8)
        position += size
    require(symtab is not None, 'Missing Mach-O symbols')
    offset, count, strings, string_size = symtab
    symbols = {}
    for i in range(count):
        index, kind, section, _, value = struct.unpack_from('<IBBHQ', blob, offset + i * 16)
        require(index < string_size, 'Invalid Mach-O symbol string')
        start = strings + index
        name = blob[start:blob.index(0, start, strings + string_size)].decode()
        if name.startswith('_air_'):
            name = name[1:]
            require(kind == 0x0f and 1 <= section <= len(sections) and name not in symbols, 'Invalid AIR symbol')
            address, length, raw_offset = sections[section - 1]
            require(address <= value < address + length, 'AIR symbol outside section')
            symbols[name] = (raw_offset + value - address, raw_offset + length)
    return symbols

if __name__ == '__main__':
    require(len(sys.argv) == 3, 'Usage: extract-dxmt-shaders.py STOCK_ROOT PATCHED_SOURCE_ROOT')
    stock, source = map(pathlib.Path, sys.argv[1:])
    binaries = {}
    for name, digest in BINARIES.items():
        data = (stock / name).read_bytes()
        require(hashlib.sha256(data).hexdigest() == digest, 'Stock binary pin mismatch: ' + name)
        binaries[name] = data
    arrays = {}
    for architecture in ('x86_64-windows', 'i386-windows'):
        data = binaries[architecture + '/d3d11.dll']
        arrays['dxmt_command'] = array(data, pe_symbols(data), 'dxmt_command')
    data = binaries['x86_64-unix/winemetal.so']
    symbols = macho_symbols(data)
    for name in ('air_msad', 'air_samplepos', 'air_tessellation'):
        arrays[name] = array(data, symbols, name)
    for name, data in arrays.items():
        header = source / 'src' / ('dxmt' if name == 'dxmt_command' else 'airconv') / (name + '.h')
        body = '\n'.join('  ' + ', '.join(f'0x{byte:02x}' for byte in data[i:i + 12]) + ',' for i in range(0, len(data), 12))
        header.write_text(f'/* Unchanged public DXMT v0.80 generated input; see extract-dxmt-shaders.py. */\nunsigned char {name}[] = {{\n{body}\n}};\nunsigned int {name}_len = {len(data)};\n')
        print(name, len(data), hashlib.sha256(data).hexdigest())
