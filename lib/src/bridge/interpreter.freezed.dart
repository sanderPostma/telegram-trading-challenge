// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'interpreter.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Size {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Size()';
}


}

/// @nodoc
class $SizeCopyWith<$Res>  {
$SizeCopyWith(Size _, $Res Function(Size) __);
}


/// Adds pattern-matching-related methods to [Size].
extension SizePatterns on Size {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Size_Usd value)?  usd,TResult Function( Size_Btc value)?  btc,TResult Function( Size_Pct value)?  pct,TResult Function( Size_FullClose value)?  fullClose,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Size_Usd() when usd != null:
return usd(_that);case Size_Btc() when btc != null:
return btc(_that);case Size_Pct() when pct != null:
return pct(_that);case Size_FullClose() when fullClose != null:
return fullClose(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Size_Usd value)  usd,required TResult Function( Size_Btc value)  btc,required TResult Function( Size_Pct value)  pct,required TResult Function( Size_FullClose value)  fullClose,}){
final _that = this;
switch (_that) {
case Size_Usd():
return usd(_that);case Size_Btc():
return btc(_that);case Size_Pct():
return pct(_that);case Size_FullClose():
return fullClose(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Size_Usd value)?  usd,TResult? Function( Size_Btc value)?  btc,TResult? Function( Size_Pct value)?  pct,TResult? Function( Size_FullClose value)?  fullClose,}){
final _that = this;
switch (_that) {
case Size_Usd() when usd != null:
return usd(_that);case Size_Btc() when btc != null:
return btc(_that);case Size_Pct() when pct != null:
return pct(_that);case Size_FullClose() when fullClose != null:
return fullClose(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( double field0)?  usd,TResult Function( double field0)?  btc,TResult Function( double field0)?  pct,TResult Function()?  fullClose,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Size_Usd() when usd != null:
return usd(_that.field0);case Size_Btc() when btc != null:
return btc(_that.field0);case Size_Pct() when pct != null:
return pct(_that.field0);case Size_FullClose() when fullClose != null:
return fullClose();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( double field0)  usd,required TResult Function( double field0)  btc,required TResult Function( double field0)  pct,required TResult Function()  fullClose,}) {final _that = this;
switch (_that) {
case Size_Usd():
return usd(_that.field0);case Size_Btc():
return btc(_that.field0);case Size_Pct():
return pct(_that.field0);case Size_FullClose():
return fullClose();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( double field0)?  usd,TResult? Function( double field0)?  btc,TResult? Function( double field0)?  pct,TResult? Function()?  fullClose,}) {final _that = this;
switch (_that) {
case Size_Usd() when usd != null:
return usd(_that.field0);case Size_Btc() when btc != null:
return btc(_that.field0);case Size_Pct() when pct != null:
return pct(_that.field0);case Size_FullClose() when fullClose != null:
return fullClose();case _:
  return null;

}
}

}

/// @nodoc


class Size_Usd extends Size {
  const Size_Usd(this.field0): super._();
  

 final  double field0;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Size_UsdCopyWith<Size_Usd> get copyWith => _$Size_UsdCopyWithImpl<Size_Usd>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size_Usd&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'Size.usd(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Size_UsdCopyWith<$Res> implements $SizeCopyWith<$Res> {
  factory $Size_UsdCopyWith(Size_Usd value, $Res Function(Size_Usd) _then) = _$Size_UsdCopyWithImpl;
@useResult
$Res call({
 double field0
});




}
/// @nodoc
class _$Size_UsdCopyWithImpl<$Res>
    implements $Size_UsdCopyWith<$Res> {
  _$Size_UsdCopyWithImpl(this._self, this._then);

  final Size_Usd _self;
  final $Res Function(Size_Usd) _then;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Size_Usd(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class Size_Btc extends Size {
  const Size_Btc(this.field0): super._();
  

 final  double field0;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Size_BtcCopyWith<Size_Btc> get copyWith => _$Size_BtcCopyWithImpl<Size_Btc>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size_Btc&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'Size.btc(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Size_BtcCopyWith<$Res> implements $SizeCopyWith<$Res> {
  factory $Size_BtcCopyWith(Size_Btc value, $Res Function(Size_Btc) _then) = _$Size_BtcCopyWithImpl;
@useResult
$Res call({
 double field0
});




}
/// @nodoc
class _$Size_BtcCopyWithImpl<$Res>
    implements $Size_BtcCopyWith<$Res> {
  _$Size_BtcCopyWithImpl(this._self, this._then);

  final Size_Btc _self;
  final $Res Function(Size_Btc) _then;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Size_Btc(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class Size_Pct extends Size {
  const Size_Pct(this.field0): super._();
  

 final  double field0;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Size_PctCopyWith<Size_Pct> get copyWith => _$Size_PctCopyWithImpl<Size_Pct>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size_Pct&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'Size.pct(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Size_PctCopyWith<$Res> implements $SizeCopyWith<$Res> {
  factory $Size_PctCopyWith(Size_Pct value, $Res Function(Size_Pct) _then) = _$Size_PctCopyWithImpl;
@useResult
$Res call({
 double field0
});




}
/// @nodoc
class _$Size_PctCopyWithImpl<$Res>
    implements $Size_PctCopyWith<$Res> {
  _$Size_PctCopyWithImpl(this._self, this._then);

  final Size_Pct _self;
  final $Res Function(Size_Pct) _then;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Size_Pct(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class Size_FullClose extends Size {
  const Size_FullClose(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size_FullClose);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Size.fullClose()';
}


}




// dart format on
