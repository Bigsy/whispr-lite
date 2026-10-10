"""Bounded read-only Chromium local-storage snapshot; never opens the live LevelDB for writing.

Reads SST blocks and write-batch logs, resolving sequence numbers and tombstones.
Only selected setting keys are returned. No history, credentials or cookies are exported.
"""
from pathlib import Path
import struct

LIMIT = 16 * 1024 * 1024


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError('Truncated LevelDB integer')
        byte = data[offset]; offset += 1; value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError('Invalid LevelDB integer')


def snappy(data):
    length, offset = varint(data, 0)
    if length > LIMIT:
        raise ValueError('Oversized LevelDB block')
    output = bytearray()
    while offset < len(data):
        tag = data[offset]; offset += 1; kind = tag & 3
        if kind == 0:
            count = tag >> 2
            if count >= 60:
                size = count - 59
                count = int.from_bytes(data[offset:offset + size], 'little'); offset += size
            count += 1
            if offset + count > len(data):
                raise ValueError('Truncated Snappy literal')
            output.extend(data[offset:offset + count]); offset += count
        else:
            if kind == 1:
                count = 4 + ((tag >> 2) & 7)
                if offset >= len(data): raise ValueError('Truncated Snappy copy')
                distance = ((tag & 224) << 3) | data[offset]; offset += 1
            else:
                count = 1 + (tag >> 2); size = 2 if kind == 2 else 4
                if offset + size > len(data): raise ValueError('Truncated Snappy copy')
                distance = int.from_bytes(data[offset:offset + size], 'little'); offset += size
            if distance == 0 or distance > len(output):
                raise ValueError('Invalid Snappy backreference')
            for _ in range(count): output.append(output[-distance])
        if len(output) > length:
            raise ValueError('Oversized Snappy output')
    if len(output) != length:
        raise ValueError('Truncated Snappy output')
    return bytes(output)


def entries(block):
    if len(block) < 4: raise ValueError('Truncated LevelDB block')
    restarts = struct.unpack_from('<I', block, len(block) - 4)[0]
    end = len(block) - 4 * (restarts + 1)
    if end < 0: raise ValueError('Invalid LevelDB restart table')
    offset = 0; previous = b''
    while offset < end:
        shared, offset = varint(block, offset)
        unshared, offset = varint(block, offset)
        length, offset = varint(block, offset)
        if shared > len(previous) or offset + unshared + length > end:
            raise ValueError('Invalid LevelDB entry')
        key = previous[:shared] + block[offset:offset + unshared]; offset += unshared
        value = block[offset:offset + length]; offset += length
        yield key, value
        previous = key


def table(data):
    if len(data) < 48 or data[-8:] != struct.pack('<Q', 0xdb4775248b80fb57):
        raise ValueError('Invalid LevelDB table footer')
    def read(handle):
        offset, cursor = varint(handle, 0); size, _ = varint(handle, cursor)
        if offset + size + 5 > len(data): raise ValueError('Invalid LevelDB block handle')
        block = data[offset:offset + size]; kind = data[offset + size]
        if kind == 1: return snappy(block)
        if kind != 0: raise ValueError('Unsupported LevelDB compression')
        return block
    footer = data[-48:-8]
    _, offset = varint(footer, 0); _, offset = varint(footer, offset)
    for _, handle in entries(read(footer[offset:])):
        yield from entries(read(handle))


def records(data):
    pending = bytearray()
    for base in range(0, len(data), 32768):
        offset = base; end = min(base + 32768, len(data))
        while offset + 7 <= end:
            _, size, kind = struct.unpack_from('<IHB', data, offset); offset += 7
            if kind == 0 and size == 0: break
            if offset + size > end: raise ValueError('Truncated LevelDB log record')
            fragment = data[offset:offset + size]; offset += size
            if kind == 1: yield fragment
            elif kind == 2: pending = bytearray(fragment)
            elif kind == 3: pending.extend(fragment)
            elif kind == 4:
                pending.extend(fragment); yield bytes(pending); pending.clear()
            else: raise ValueError('Invalid LevelDB log record')
            if len(pending) > LIMIT: raise ValueError('Oversized LevelDB log record')
    if pending: raise ValueError('Incomplete LevelDB log record; close OpenWhispr and retry')


def batches(data):
    for record in records(data):
        if len(record) < 12: raise ValueError('Truncated LevelDB write batch')
        sequence, count = struct.unpack_from('<QI', record)
        offset = 12
        for index in range(count):
            if offset >= len(record): raise ValueError('Truncated LevelDB write batch')
            kind = record[offset]; offset += 1
            length, offset = varint(record, offset)
            key = record[offset:offset + length]; offset += length
            value = b''
            if kind == 1:
                length, offset = varint(record, offset)
                value = record[offset:offset + length]; offset += length
            elif kind != 0: raise ValueError('Unsupported LevelDB write operation')
            if offset > len(record): raise ValueError('Truncated LevelDB write batch')
            yield key, sequence + index, kind, value
        if offset != len(record): raise ValueError('Invalid LevelDB write batch length')


def text(value):
    if not value: return ''
    if value[0] == 1: return value[1:].decode('latin1')
    if value[0] == 0: return value[1:].decode('utf-16-le')
    raise ValueError('Unsupported Chromium string encoding')


def read_settings(directory, selected):
    latest = {}
    for path in sorted(Path(directory).iterdir()):
        if path.suffix not in ['.ldb', '.sst', '.log']: continue
        if path.stat().st_size > LIMIT: raise ValueError('Oversized settings file')
        before = path.stat(); data = path.read_bytes(); after = path.stat()
        if (before.st_mtime_ns, before.st_size) != (after.st_mtime_ns, after.st_size):
            raise ValueError('Settings changed during read; close OpenWhispr and retry')
        if path.suffix == '.log':
            values = batches(data)
        else:
            values = ((key[:-8], int.from_bytes(key[-8:], 'little') >> 8,
                       key[-8], value) for key, value in table(data) if len(key) >= 8)
        for key, sequence, kind, value in values:
            if not key.startswith(b'_file://\x00'): continue
            name = text(key.split(b'\x00', 1)[1])
            if name in selected and (name not in latest or sequence > latest[name][0]):
                latest[name] = (sequence, text(value) if kind == 1 else None)
    return {key: value for key, (_, value) in latest.items() if value is not None}
