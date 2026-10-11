"""Passive, layout-gated LLDB formatters for stock Crystal 1.21 values."""

import codecs
import json
import lldb


STRING_PREVIEW_MAX_BYTES = 1024
ARRAY_PREVIEW_MAX_ELEMENTS = 8
ARRAY_CHILDREN_MAX = 256
ARRAY_PREVIEW_MAX_BYTES = 64

_UINT64_MAX = (1 << 64) - 1


class _Unavailable(Exception):
    pass


def _valid(value):
    return value is not None and value.IsValid()


def _non_synthetic(value):
    if not _valid(value):
        raise _Unavailable("invalid value")
    plain = value.GetNonSyntheticValue()
    if not _valid(plain):
        raise _Unavailable("raw value unavailable")
    return plain


def _target_process(value):
    target = value.GetTarget()
    if not _valid(target):
        raise _Unavailable("target metadata unavailable")
    if target.GetAddressByteSize() != 8:
        raise _Unavailable("requires a 64-bit target")
    if target.GetByteOrder() != lldb.eByteOrderLittle:
        raise _Unavailable("requires a little-endian target")
    process = target.GetProcess()
    if not _valid(process):
        raise _Unavailable("process memory unavailable")
    return target, process


def _type_fields(type_value, expected_name, expected_size, expected_fields):
    if not _valid(type_value):
        raise _Unavailable("DWARF type unavailable")
    if type_value.GetName() != expected_name:
        raise _Unavailable("unexpected type name")
    if type_value.GetTypeClass() != lldb.eTypeClassStruct:
        raise _Unavailable("value is not a DWARF struct")
    if type_value.GetByteSize() != expected_size:
        raise _Unavailable("unexpected struct size")
    if type_value.GetNumberOfFields() != len(expected_fields):
        raise _Unavailable("unexpected DWARF field count")
    fields = {}
    for index in range(type_value.GetNumberOfFields()):
        member = type_value.GetFieldAtIndex(index)
        name = member.GetName()
        if not name or name in fields or member.IsBitfield():
            raise _Unavailable("invalid or duplicate DWARF field")
        fields[name] = member
    if set(fields) != set(expected_fields):
        raise _Unavailable("unexpected DWARF member names")
    for name, (offset, type_name, size, *class_spec) in expected_fields.items():
        member = fields[name]
        member_type = member.GetType()
        if member.GetOffsetInBytes() != offset:
            raise _Unavailable("unexpected offset for " + name)
        if not _valid(member_type) or (type_name is not None and member_type.GetName() != type_name):
            raise _Unavailable("unexpected type for " + name)
        if member_type.GetByteSize() != size:
            raise _Unavailable("unexpected size for " + name)
        expected_class = class_spec[0] if class_spec else lldb.eTypeClassBuiltin
        if member_type.GetTypeClass() != expected_class:
            raise _Unavailable("unexpected DWARF class for " + name)
    return fields


_STRING_FIELDS = {
    "bytesize": (4, "int", 4),
    "length": (8, "int", 4),
    "c": (12, "unsigned char", 1),
}
_ARRAY_FIELDS = {
    "size": (4, "int", 4),
    "capacity": (8, "int", 4),
    "offset_to_buffer": (12, "int", 4),
    "buffer": (16, None, 8, lldb.eTypeClassPointer),
}


def _member(value, name):
    member = value.GetChildMemberWithName(name)
    if not _valid(member):
        raise _Unavailable("DWARF member unavailable: " + name)
    return member


def _signed_value(value, name):
    scalar = _member(value, name)
    error = lldb.SBError()
    number = scalar.GetValueAsSigned(error, 0)
    if not error.Success():
        raise _Unavailable("cannot read DWARF member: " + name)
    return int(number)


def _unsigned_value(value):
    error = lldb.SBError()
    number = value.GetValueAsUnsigned(error, 0)
    if not error.Success():
        raise _Unavailable("cannot read buffer pointer")
    return int(number)


def _passive_struct(value):
    """Resolve an inline Crystal struct or one pointer to it without evaluation."""
    source = _non_synthetic(value)
    target, process = _target_process(source)
    type_value = source.GetType()
    if not _valid(type_value):
        raise _Unavailable("DWARF value type unavailable")

    type_class = type_value.GetTypeClass()
    if type_class == lldb.eTypeClassPointer:
        pointer_size = target.GetAddressByteSize()
        if type_value.GetByteSize() != pointer_size:
            raise _Unavailable("Crystal object pointer width mismatch")
        struct_type = type_value.GetPointeeType()
        if not _valid(struct_type) or struct_type.GetTypeClass() != lldb.eTypeClassStruct:
            raise _Unavailable("Crystal object pointer has no struct pointee")
        address = _unsigned_value(source)
        invalid_address = getattr(lldb, "LLDB_INVALID_ADDRESS", _UINT64_MAX)
        if address in (0, _UINT64_MAX, invalid_address):
            raise _Unavailable("null or invalid Crystal object pointer")
        struct_value = _non_synthetic(source.Dereference())
        actual_type = struct_value.GetType()
        if not _valid(actual_type) or actual_type.GetTypeClass() != lldb.eTypeClassStruct:
            raise _Unavailable("dereferenced Crystal value is not a struct")
        if actual_type.GetName() != struct_type.GetName() or actual_type.GetByteSize() != struct_type.GetByteSize():
            raise _Unavailable("dereferenced Crystal value disagrees with pointer DWARF")
    elif type_class == lldb.eTypeClassStruct:
        struct_value = source
        actual_type = type_value
        address = int(struct_value.GetLoadAddress())
        invalid_address = getattr(lldb, "LLDB_INVALID_ADDRESS", _UINT64_MAX)
        if address in (0, _UINT64_MAX, invalid_address):
            raise _Unavailable("null or invalid Crystal struct address")
    else:
        raise _Unavailable("Crystal value is not a struct or struct pointer")

    if address > _UINT64_MAX or actual_type.GetByteSize() > _UINT64_MAX - address:
        raise _Unavailable("Crystal object address range overflow")
    return struct_value, target, process, actual_type, address


def _string_layout(value):
    plain, target, process, type_value, address = _passive_struct(value)
    if not _valid(type_value) or type_value.GetName() != "String":
        raise _Unavailable("not a stock Crystal String struct")
    fields = _type_fields(type_value, "String", 16, _STRING_FIELDS)
    byte_size = _signed_value(plain, "bytesize")
    if byte_size < 0:
        raise _Unavailable("negative String byte size")
    data_address = address + fields["c"].GetOffsetInBytes()
    if data_address > _UINT64_MAX or byte_size > _UINT64_MAX - data_address:
        raise _Unavailable("String address range overflow")
    return plain, target, process, data_address, byte_size


def _read_memory(process, address, count):
    if count < 0 or count > STRING_PREVIEW_MAX_BYTES:
        raise _Unavailable("memory read exceeds provider bound")
    if count == 0:
        return b""
    error = lldb.SBError()
    result = process.ReadMemory(address, count, error)
    if not error.Success():
        raise _Unavailable("target memory read failed")
    if isinstance(result, str):
        result = result.encode("latin-1", errors="strict")
    try:
        data = bytes(result)
    except (TypeError, ValueError):
        raise _Unavailable("target memory returned non-byte data")
    if len(data) != count:
        raise _Unavailable("short target memory read")
    return data


def crystal_string_summary(value, internal_dict):
    """Return bounded UTF-8 text or escaped raw bytes when UTF-8 is invalid."""
    try:
        _plain, _target, process, address, byte_size = _string_layout(value)
        read_size = min(byte_size, STRING_PREVIEW_MAX_BYTES)
        data = _read_memory(process, address, read_size)
        clipped = read_size < byte_size
        decoder = codecs.getincrementaldecoder("utf-8")("strict")
        try:
            text = decoder.decode(data, final=not clipped)
        except UnicodeDecodeError:
            detail = "invalid UTF-8 in preview" if clipped else "invalid UTF-8 bytes"
            return f"{data!r} ({detail}; {byte_size} bytes)"
        if clipped:
            text += "…"
        display = json.dumps(text, ensure_ascii=False)
        if clipped:
            return f"{display} ({byte_size} bytes; preview limited to {STRING_PREVIEW_MAX_BYTES} bytes)"
        return f"{display} ({byte_size} bytes)"
    except _Unavailable as error:
        return f"String <unavailable: {error}>"
    except Exception as error:
        return f"String <unavailable: formatter error: {type(error).__name__}>"


_SIGNED_BASIC_TYPES = {
    getattr(lldb, "eBasicTypeSignedChar", -1): 1,
    getattr(lldb, "eBasicTypeShort", -1): 2,
    getattr(lldb, "eBasicTypeInt", -1): 4,
    getattr(lldb, "eBasicTypeLong", -1): 8,
    getattr(lldb, "eBasicTypeLongLong", -1): 8,
}
_UNSIGNED_BASIC_TYPES = {
    getattr(lldb, "eBasicTypeUnsignedChar", -1): 1,
    getattr(lldb, "eBasicTypeUnsignedShort", -1): 2,
    getattr(lldb, "eBasicTypeUnsignedInt", -1): 4,
    getattr(lldb, "eBasicTypeUnsignedLong", -1): 8,
    getattr(lldb, "eBasicTypeUnsignedLongLong", -1): 8,
}


def _integer_metadata(pointer_type):
    if not _valid(pointer_type) or not pointer_type.IsPointerType():
        raise _Unavailable("Array buffer is not a pointer")
    pointee = pointer_type.GetPointeeType()
    if not _valid(pointee) or pointee.GetTypeClass() != lldb.eTypeClassBuiltin:
        raise _Unavailable("unsupported Array element metadata")
    width = int(pointee.GetByteSize())
    basic_type = pointee.GetBasicType()
    signed_width = _SIGNED_BASIC_TYPES.get(basic_type)
    unsigned_width = _UNSIGNED_BASIC_TYPES.get(basic_type)
    if signed_width == width and width in (1, 2, 4, 8):
        return pointee, width, True
    if unsigned_width == width and width in (1, 2, 4, 8):
        return pointee, width, False
    raise _Unavailable("unsupported primitive Array element type")


def _array_layout(value):
    plain, target, process, type_value, address = _passive_struct(value)
    if not _valid(type_value) or not type_value.GetName().startswith("Array(") or not type_value.GetName().endswith(")"):
        raise _Unavailable("not a stock Crystal Array struct")
    fields = _type_fields(type_value, type_value.GetName(), 24, _ARRAY_FIELDS)
    buffer_type = fields["buffer"].GetType()
    if not _valid(buffer_type) or not buffer_type.IsPointerType():
        raise _Unavailable("Array buffer field is not a pointer")
    if target.GetAddressByteSize() != buffer_type.GetByteSize():
        raise _Unavailable("Array pointer size mismatch")
    size = _signed_value(plain, "size")
    capacity = _signed_value(plain, "capacity")
    offset = _signed_value(plain, "offset_to_buffer")
    if size < 0 or capacity < 0 or offset < 0 or offset > capacity or size > capacity - offset:
        raise _Unavailable("inconsistent Array size/capacity/offset")
    buffer_value = _member(plain, "buffer")
    buffer_type = fields["buffer"].GetType()
    pointee, stride, signed = _integer_metadata(buffer_type)
    address = _unsigned_value(buffer_value)
    invalid_address = getattr(lldb, "LLDB_INVALID_ADDRESS", _UINT64_MAX)
    if address in (_UINT64_MAX, invalid_address):
        raise _Unavailable("invalid Array buffer address")
    if size > 0 and address == 0:
        raise _Unavailable("null or invalid Array buffer")
    if size > _UINT64_MAX // stride:
        raise _Unavailable("Array byte range overflow")
    byte_count = size * stride
    if address > _UINT64_MAX or byte_count > _UINT64_MAX - address:
        raise _Unavailable("Array address range overflow")
    return plain, target, process, size, capacity, offset, address, pointee, stride, signed


def _array_preview(value):
    layout = _array_layout(value)
    _plain, target, process, size, _capacity, _offset, address, pointee, stride, signed = layout
    shown = min(size, ARRAY_PREVIEW_MAX_ELEMENTS)
    byte_count = shown * stride
    if byte_count > ARRAY_PREVIEW_MAX_BYTES:
        raise _Unavailable("Array preview exceeds provider bound")
    data = _read_memory(process, address, byte_count)
    values = [
        int.from_bytes(
            data[index * stride:(index + 1) * stride],
            byteorder="little" if target.GetByteOrder() == lldb.eByteOrderLittle else "big",
            signed=signed,
        )
        for index in range(shown)
    ]
    return layout, values


def crystal_array_summary(value, internal_dict):
    try:
        layout, values = _array_preview(value)
        _plain, _target, _process, size, _capacity, _offset, _address, pointee, _stride, _signed = layout
        rendered = ", ".join(str(item) for item in values)
        if size > len(values):
            rendered += ", …" if rendered else "…"
        summary = f"[{rendered}] (size={size})"
        if size > ARRAY_PREVIEW_MAX_ELEMENTS:
            summary += f"; preview shows {ARRAY_PREVIEW_MAX_ELEMENTS} of {size}"
        if size > ARRAY_CHILDREN_MAX:
            summary += f"; indexed children capped at {ARRAY_CHILDREN_MAX}"
        return summary
    except _Unavailable as error:
        return f"Array <unavailable: {error}; raw fields available>"
    except Exception as error:
        return f"Array <unavailable: formatter error: {type(error).__name__}; raw fields available>"


class ArraySynthetic:
    """Lazily expose bounded numeric Array elements, or raw struct fields."""

    def __init__(self, value, internal_dict):
        self.value = value
        self.internal_dict = internal_dict
        self.update()

    def update(self):
        self.plain = None
        self.layout = None
        self.error = None
        try:
            self.layout = _array_layout(self.value)
            self.plain = self.layout[0]
        except _Unavailable as error:
            try:
                self.plain = _non_synthetic(self.value)
            except _Unavailable:
                self.plain = None
            self.error = str(error)
        except Exception as error:
            try:
                self.plain = _non_synthetic(self.value)
            except _Unavailable:
                self.plain = None
            self.error = "formatter error: " + type(error).__name__
        # LLDB requires False here so that stop-to-stop value changes refresh.
        return False

    def has_children(self):
        if self.layout is not None:
            return self.layout[3] > 0
        return self.plain is not None and self.plain.GetNumChildren() > 0

    def num_children(self, max_children):
        if self.layout is None:
            return min(self.plain.GetNumChildren(), ARRAY_CHILDREN_MAX) if self.plain is not None else 0
        size = self.layout[3]
        requested = int(max_children) if max_children is not None else 0
        count = min(size, ARRAY_CHILDREN_MAX)
        if requested > 0:
            count = min(count, requested)
        return count

    def get_child_at_index(self, index):
        index = int(index)
        if index < 0:
            return lldb.SBValue()
        if self.layout is None:
            if self.plain is None or index >= min(self.plain.GetNumChildren(), ARRAY_CHILDREN_MAX):
                return lldb.SBValue()
            return self.plain.GetChildAtIndex(index, lldb.eNoDynamicValues, True)
        _plain, _target, _process, size, _capacity, _offset, address, pointee, stride, _signed = self.layout
        if index >= min(size, ARRAY_CHILDREN_MAX):
            return lldb.SBValue()
        child_address = address + index * stride
        if child_address > _UINT64_MAX or stride > _UINT64_MAX - child_address:
            return lldb.SBValue()
        child = self.plain.CreateValueFromAddress(f"[{index}]", child_address, pointee)
        return child if _valid(child) else lldb.SBValue()


def register(debugger):
    """Install only the stock-Crystal String and numeric Array formatters."""
    commands = [
        "type summary add -F adamantine_crystal.crystal_string_summary String",
        "type summary add -F adamantine_crystal.crystal_array_summary -x '^Array\\(.*\\)$'",
        "type synthetic add -l adamantine_crystal.ArraySynthetic -x '^Array\\(.*\\)$'",
    ]
    interpreter = debugger.GetCommandInterpreter()
    for command in commands:
        result = lldb.SBCommandReturnObject()
        interpreter.HandleCommand(command, result)
        if not result.Succeeded():
            raise RuntimeError("could not register Crystal formatter: " + result.GetError())


def __lldb_init_module(debugger, internal_dict):
    register(debugger)
