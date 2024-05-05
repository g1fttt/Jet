// Code generated by "stringer -type=PrimitiveKind -linecomment -output=primitive_kind_string.go"; DO NOT EDIT.

package types

import "strconv"

func _() {
	// An "invalid array index" compiler error signifies that the constant values have changed.
	// Re-run the stringer command to generate them again.
	var x [1]struct{}
	_ = x[UnknownPrimitive-0]
	_ = x[UntypedBool-1]
	_ = x[UntypedInt-2]
	_ = x[UntypedFloat-3]
	_ = x[UntypedString-4]
	_ = x[Bool-5]
	_ = x[I32-6]
	_ = x[Any-7]
	_ = x[AnyTypeDesc-8]
}

const _PrimitiveKind_name = "UnknownPrimitiveuntyped booluntyped intuntyped floatuntyped stringbooli32anytypedesc"

var _PrimitiveKind_index = [...]uint8{0, 16, 28, 39, 52, 66, 70, 73, 76, 84}

func (i PrimitiveKind) String() string {
	if i >= PrimitiveKind(len(_PrimitiveKind_index)-1) {
		return "PrimitiveKind(" + strconv.FormatInt(int64(i), 10) + ")"
	}
	return _PrimitiveKind_name[_PrimitiveKind_index[i]:_PrimitiveKind_index[i+1]]
}
