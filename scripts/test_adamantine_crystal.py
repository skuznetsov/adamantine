#!/usr/bin/env python3
"""Hostile unit falsifiers for the passive Crystal LLDB provider."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROVIDER = ROOT / "tools/lldb/adamantine_crystal.py"
U64_MAX = (1 << 64) - 1


class FakeError:
    def __init__(self, success=True):
        self.success = success

    def Success(self):
        return self.success


class FakeMember:
    def __init__(self, name, offset, type_value, bitfield=False):
        self.name = name
        self.offset = offset
        self.type_value = type_value
        self.bitfield = bitfield

    def GetName(self):
        return self.name

    def GetOffsetInBytes(self):
        return self.offset

    def GetType(self):
        return self.type_value

    def IsBitfield(self):
        return self.bitfield


class FakeType:
    def __init__(self, name, type_class, size, *, fields=(), pointee=None, basic=-1):
        self.name = name
        self.type_class = type_class
        self.size = size
        self.fields = list(fields)
        self.pointee = pointee
        self.basic = basic

    def IsValid(self):
        return True

    def GetName(self):
        return self.name

    def GetTypeClass(self):
        return self.type_class

    def GetByteSize(self):
        return self.size

    def GetNumberOfFields(self):
        return len(self.fields)

    def GetFieldAtIndex(self, index):
        return self.fields[index]

    def IsPointerType(self):
        return self.type_class == LLDB.eTypeClassPointer

    def GetPointeeType(self):
        return self.pointee

    def GetBasicType(self):
        return self.basic


class FakeProcess:
    def __init__(self):
        self.regions: list[tuple[int, bytes]] = []
        self.reads: list[tuple[int, int]] = []
        self.evaluation_calls = 0
        self.write_calls = 0

    def IsValid(self):
        return True

    def add(self, address: int, data: bytes) -> None:
        self.regions.append((address, bytes(data)))

    def ReadMemory(self, address, count, error):
        self.reads.append((address, count))
        for base, data in self.regions:
            start = address - base
            if 0 <= start <= len(data):
                return data[start:start + count]
        error.success = False
        return b""

    def EvaluateExpression(self, *_args, **_kwargs):
        self.evaluation_calls += 1
        raise AssertionError("target expression evaluation is forbidden")

    def WriteMemory(self, *_args, **_kwargs):
        self.write_calls += 1
        raise AssertionError("target writes are forbidden")


class FakeTarget:
    def __init__(self, process):
        self.process = process

    def IsValid(self):
        return True

    def GetAddressByteSize(self):
        return 8

    def GetByteOrder(self):
        return LLDB.eByteOrderLittle

    def GetProcess(self):
        return self.process


class FakeValue:
    def __init__(self, type_value=None, *, target=None, address=0, number=None,
                 fields=None, dereference=None, raw_children=0, valid=True,
                 create_child=None):
        self.type_value = type_value
        self.target = target
        self.address = address
        self.number = number
        self.fields = fields or {}
        self.dereference_value = dereference
        self.raw_children = raw_children
        self.valid = valid
        self.create_child = create_child
        self.created: list[tuple[str, int, FakeType]] = []
        self.non_synthetic_calls = 0

    def IsValid(self):
        return self.valid

    def GetNonSyntheticValue(self):
        self.non_synthetic_calls += 1
        return self

    def GetTarget(self):
        return self.target

    def GetType(self):
        return self.type_value

    def GetLoadAddress(self):
        return self.address if self.address else LLDB.LLDB_INVALID_ADDRESS

    def GetValueAsUnsigned(self, error, default=0):
        if self.number is None:
            return default
        return self.number

    def GetValueAsSigned(self, error, default=0):
        if self.number is None:
            return default
        return self.number

    def GetChildMemberWithName(self, name):
        return self.fields.get(name, FakeValue(valid=False))

    def Dereference(self):
        return self.dereference_value or FakeValue(valid=False)

    def CreateValueFromAddress(self, name, address, type_value):
        self.created.append((name, address, type_value))
        if self.create_child is None:
            number = 0
            if self.target and type_value.GetByteSize() > 0:
                process = self.target.GetProcess()
                data = process.ReadMemory(address, type_value.GetByteSize(), FakeError())
                if len(data) == type_value.GetByteSize():
                    signed = type_value.GetBasicType() in {
                        LLDB.eBasicTypeSignedChar,
                        LLDB.eBasicTypeShort,
                        LLDB.eBasicTypeInt,
                        LLDB.eBasicTypeLong,
                        LLDB.eBasicTypeLongLong,
                    }
                    number = int.from_bytes(data, "little", signed=signed)
            return FakeValue(type_value, number=number)
        return self.create_child(name, address, type_value)

    def GetNumChildren(self):
        return self.raw_children

    def GetChildAtIndex(self, index, *_args):
        return FakeValue(valid=index < self.raw_children)

    def EvaluateExpression(self, *_args, **_kwargs):
        raise AssertionError("target expression evaluation is forbidden")

    def WriteMemory(self, *_args, **_kwargs):
        raise AssertionError("target writes are forbidden")


LLDB = types.SimpleNamespace(
    eByteOrderLittle=4,
    eTypeClassStruct=1,
    eTypeClassBuiltin=2,
    eTypeClassPointer=3,
    eBasicTypeSignedChar=3,
    eBasicTypeUnsignedChar=4,
    eBasicTypeShort=11,
    eBasicTypeUnsignedShort=12,
    eBasicTypeInt=13,
    eBasicTypeUnsignedInt=14,
    eBasicTypeLong=15,
    eBasicTypeUnsignedLong=16,
    eBasicTypeLongLong=17,
    eBasicTypeUnsignedLongLong=18,
    eNoDynamicValues=0,
    LLDB_INVALID_ADDRESS=U64_MAX,
    SBError=FakeError,
    SBValue=lambda: FakeValue(valid=False),
)
sys.modules["lldb"] = LLDB
spec = importlib.util.spec_from_file_location("adamantine_crystal", PROVIDER)
assert spec and spec.loader
provider = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = provider
spec.loader.exec_module(provider)


def builtin(name, size, basic):
    return FakeType(name, LLDB.eTypeClassBuiltin, size, basic=basic)


INT = builtin("int", 4, LLDB.eBasicTypeInt)
UCHAR = builtin("unsigned char", 1, LLDB.eBasicTypeUnsignedChar)


def crystal_struct(name, fields):
    return FakeType(name, LLDB.eTypeClassStruct, 16 if name == "String" else 24, fields=fields)


def string_value(data, *, byte_size=None, offset=0x4000, type_name="String"):
    process = FakeProcess()
    process.add(offset + 12, data)
    fields = [
        FakeMember("bytesize", 4, INT),
        FakeMember("length", 8, INT),
        FakeMember("c", 12, UCHAR),
    ]
    struct_type = crystal_struct(type_name, fields)
    struct = FakeValue(
        struct_type,
        target=FakeTarget(process),
        address=offset,
        fields={
            "bytesize": FakeValue(INT, number=len(data) if byte_size is None else byte_size),
            "length": FakeValue(INT, number=len(data) if byte_size is None else byte_size),
            "c": FakeValue(UCHAR, number=data[0] if data else 0),
        },
    )
    pointer_type = FakeType("String *", LLDB.eTypeClassPointer, 8, pointee=struct_type)
    pointer = FakeValue(
        pointer_type,
        target=FakeTarget(process),
        number=offset,
        dereference=struct,
    )
    return pointer, process


def array_value(values, *, size=None, capacity=None, offset=0, buffer_address=0x8000,
                element_type=None, pointer_address=0x5000, fields_override=None,
                array_name="Array(Int32)"):
    process = FakeProcess()
    element_type = element_type or INT
    stride = element_type.GetByteSize()
    if values:
        raw = b"".join(int(item).to_bytes(stride, "little", signed=True) for item in values)
        process.add(buffer_address, raw)
    buffer_type = FakeType("int *", LLDB.eTypeClassPointer, 8, pointee=element_type)
    struct_fields = [
        FakeMember("size", 4, INT),
        FakeMember("capacity", 8, INT),
        FakeMember("offset_to_buffer", 12, INT),
        FakeMember("buffer", 16, buffer_type),
    ]
    struct_type = crystal_struct(array_name, struct_fields)
    array_fields = {
        "size": FakeValue(INT, number=len(values) if size is None else size),
        "capacity": FakeValue(INT, number=len(values) if capacity is None else capacity),
        "offset_to_buffer": FakeValue(INT, number=offset),
        "buffer": FakeValue(buffer_type, number=buffer_address),
    }
    if fields_override:
        array_fields.update(fields_override)
    struct = FakeValue(struct_type, target=FakeTarget(process), address=pointer_address, fields=array_fields)
    pointer_type = FakeType(array_name + " *", LLDB.eTypeClassPointer, 8, pointee=struct_type)
    pointer = FakeValue(
        pointer_type,
        target=FakeTarget(process),
        number=pointer_address,
        dereference=struct,
        raw_children=4,
    )
    return pointer, process


class ProviderTests(unittest.TestCase):
    def test_string_empty_unicode_embedded_nul_and_bounded_large_preview(self):
        empty, empty_process = string_value(b"")
        self.assertEqual(provider.crystal_string_summary(empty, {}), '"" (0 bytes)')
        self.assertEqual(empty_process.reads, [])

        utf8, _ = string_value("snowman ☃".encode())
        self.assertEqual(provider.crystal_string_summary(utf8, {}), '"snowman ☃" (11 bytes)')

        nul, _ = string_value(b"left\x00right")
        summary = provider.crystal_string_summary(nul, {})
        self.assertIn(r"left\u0000right", summary)
        self.assertNotIn("left\x00right", summary)

        large, process = string_value(b"x" * 2048)
        summary = provider.crystal_string_summary(large, {})
        self.assertIn("2048 bytes; preview limited to 1024 bytes", summary)
        self.assertEqual(process.reads, [(0x400C, 1024)])

        split_utf8, _ = string_value(b"x" * 1023 + "☃".encode() + b"tail")
        split_summary = provider.crystal_string_summary(split_utf8, {})
        self.assertTrue(split_summary.startswith('"' + "x" * 1023 + "…"))
        self.assertNotIn("invalid UTF-8", split_summary)

    def test_string_invalid_utf8_short_read_and_null_pointer_are_honest(self):
        invalid, _ = string_value(b"ok\xff")
        summary = provider.crystal_string_summary(invalid, {})
        self.assertIn("invalid UTF-8 bytes", summary)
        self.assertIn("b'ok\\xff'", summary)
        self.assertNotIn('"ok�"', summary)

        short, process = string_value(b"ab")
        process.regions.clear()
        process.add(0x400C, b"a")
        self.assertIn("unavailable: short target memory read", provider.crystal_string_summary(short, {}))

        null, _ = string_value(b"")
        null.number = 0
        self.assertIn("null or invalid Crystal object pointer", provider.crystal_string_summary(null, {}))
        self.assertNotEqual(provider.crystal_string_summary(null, {}), '"" (0 bytes)')

    def test_string_rejects_wrong_member_offset_and_wrong_pointer_class(self):
        value, _ = string_value(b"a")
        value.dereference_value.type_value.fields[0].offset = 0
        self.assertIn("unexpected offset for bytesize", provider.crystal_string_summary(value, {}))

        wrong_class, _ = string_value(b"a")
        wrong_class.type_value = FakeType("String *", LLDB.eTypeClassBuiltin, 8)
        self.assertIn("not a struct or struct pointer", provider.crystal_string_summary(wrong_class, {}))

        wrong_width, _ = string_value(b"a")
        wrong_width.type_value = FakeType("String *", LLDB.eTypeClassPointer, 4,
                                          pointee=wrong_width.type_value.GetPointeeType())
        self.assertIn("pointer width mismatch", provider.crystal_string_summary(wrong_width, {}))

    def test_array_summary_children_are_logical_lazy_and_bounded(self):
        value, process = array_value([22, 44])
        self.assertEqual(provider.crystal_array_summary(value, {}), "[22, 44] (size=2)")
        synthetic = provider.ArraySynthetic(value, {})
        self.assertFalse(synthetic.update())
        self.assertTrue(synthetic.has_children())
        self.assertEqual(synthetic.num_children(10000), 2)
        self.assertEqual(value.dereference_value.created, [])
        self.assertEqual(synthetic.get_child_at_index(0).number, 22)
        self.assertEqual(synthetic.get_child_at_index(1).number, 44)
        self.assertEqual([item[1] for item in value.dereference_value.created], [0x8000, 0x8004])
        self.assertEqual(process.reads[0], (0x8000, 8))

        shifted, _ = array_value([5, 7], size=2, capacity=3, offset=1, buffer_address=0x9004)
        self.assertEqual(provider.crystal_array_summary(shifted, {}), "[5, 7] (size=2)")
        shifted_provider = provider.ArraySynthetic(shifted, {})
        self.assertEqual(shifted_provider.get_child_at_index(0).number, 5)
        self.assertEqual(shifted.dereference_value.created[0][1], 0x9004)

        large, _ = array_value(list(range(300)), capacity=300)
        self.assertIn("[0, 1, 2, 3, 4, 5, 6, 7, …] (size=300)", provider.crystal_array_summary(large, {}))
        self.assertIn("indexed children capped at 256", provider.crystal_array_summary(large, {}))
        self.assertLessEqual(large.target.GetProcess().reads[-1][1], 64)
        capped = provider.ArraySynthetic(large, {})
        self.assertEqual(capped.num_children(100000), 256)
        self.assertFalse(capped.get_child_at_index(256).IsValid())

    def test_array_empty_pointer_rules_and_invalid_addresses(self):
        empty, _ = array_value([], size=0, capacity=0, buffer_address=0)
        self.assertEqual(provider.crystal_array_summary(empty, {}), "[] (size=0)")

        null_nonempty, _ = array_value([1], buffer_address=0)
        self.assertIn("null or invalid Array buffer", provider.crystal_array_summary(null_nonempty, {}))

        invalid_empty, _ = array_value([], size=0, capacity=0, buffer_address=U64_MAX)
        self.assertIn("invalid Array buffer address", provider.crystal_array_summary(invalid_empty, {}))

        invalid_owner, _ = array_value([], size=0, capacity=0, buffer_address=0)
        invalid_owner.number = U64_MAX
        self.assertIn("null or invalid Crystal object pointer", provider.crystal_array_summary(invalid_owner, {}))

    def test_array_rejects_wrong_layout_stride_overflow_and_unsupported_metadata(self):
        inconsistent, _ = array_value([1], size=2, capacity=1)
        self.assertIn("inconsistent Array size/capacity/offset", provider.crystal_array_summary(inconsistent, {}))

        wrong_stride, _ = array_value([1], element_type=builtin("int", 8, LLDB.eBasicTypeInt))
        self.assertIn("unsupported primitive Array element type", provider.crystal_array_summary(wrong_stride, {}))

        unsupported, _ = array_value([1], element_type=FakeType("MyNumber", LLDB.eTypeClassStruct, 4))
        self.assertIn("unsupported Array element metadata", provider.crystal_array_summary(unsupported, {}))

        wrong_buffer_class, _ = array_value([1])
        wrong_buffer_class.dereference_value.type_value.fields[3].type_value.type_class = LLDB.eTypeClassBuiltin
        self.assertIn("unexpected DWARF class for buffer", provider.crystal_array_summary(wrong_buffer_class, {}))

        overflow, _ = array_value([1], size=1, capacity=1, buffer_address=U64_MAX - 1)
        self.assertIn("Array address range overflow", provider.crystal_array_summary(overflow, {}))

    def test_array_raw_fallback_is_capped_and_indexing_is_bounded(self):
        value, _ = array_value([1])
        value.dereference_value.type_value.fields[0].offset = 0
        synthetic = provider.ArraySynthetic(value, {})
        self.assertFalse(synthetic.update())
        self.assertIsNone(synthetic.layout)
        self.assertEqual(synthetic.num_children(100000), 4)
        value.raw_children = 900
        self.assertEqual(synthetic.num_children(100000), 256)
        self.assertFalse(synthetic.get_child_at_index(256).IsValid())

    def test_formatter_uses_no_target_evaluation_or_write_api(self):
        value, process = string_value(b"safe")
        provider.crystal_string_summary(value, {})
        array, array_process = array_value([22])
        synthetic = provider.ArraySynthetic(array, {})
        synthetic.get_child_at_index(0)
        self.assertEqual(process.evaluation_calls + process.write_calls, 0)
        self.assertEqual(array_process.evaluation_calls + array_process.write_calls, 0)
        source = PROVIDER.read_text(encoding="utf-8")
        self.assertNotIn("EvaluateExpression(", source)
        self.assertNotIn("CreateValueFromExpression(", source)
        self.assertNotIn("WriteMemory(", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
