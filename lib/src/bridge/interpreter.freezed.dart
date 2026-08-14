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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Size_Usdt value)?  usdt,TResult Function( Size_Coin value)?  coin,TResult Function( Size_Pct value)?  pct,TResult Function( Size_FullClose value)?  fullClose,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Size_Usdt() when usdt != null:
return usdt(_that);case Size_Coin() when coin != null:
return coin(_that);case Size_Pct() when pct != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Size_Usdt value)  usdt,required TResult Function( Size_Coin value)  coin,required TResult Function( Size_Pct value)  pct,required TResult Function( Size_FullClose value)  fullClose,}){
final _that = this;
switch (_that) {
case Size_Usdt():
return usdt(_that);case Size_Coin():
return coin(_that);case Size_Pct():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Size_Usdt value)?  usdt,TResult? Function( Size_Coin value)?  coin,TResult? Function( Size_Pct value)?  pct,TResult? Function( Size_FullClose value)?  fullClose,}){
final _that = this;
switch (_that) {
case Size_Usdt() when usdt != null:
return usdt(_that);case Size_Coin() when coin != null:
return coin(_that);case Size_Pct() when pct != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( double field0)?  usdt,TResult Function( double field0)?  coin,TResult Function( double field0)?  pct,TResult Function()?  fullClose,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Size_Usdt() when usdt != null:
return usdt(_that.field0);case Size_Coin() when coin != null:
return coin(_that.field0);case Size_Pct() when pct != null:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( double field0)  usdt,required TResult Function( double field0)  coin,required TResult Function( double field0)  pct,required TResult Function()  fullClose,}) {final _that = this;
switch (_that) {
case Size_Usdt():
return usdt(_that.field0);case Size_Coin():
return coin(_that.field0);case Size_Pct():
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( double field0)?  usdt,TResult? Function( double field0)?  coin,TResult? Function( double field0)?  pct,TResult? Function()?  fullClose,}) {final _that = this;
switch (_that) {
case Size_Usdt() when usdt != null:
return usdt(_that.field0);case Size_Coin() when coin != null:
return coin(_that.field0);case Size_Pct() when pct != null:
return pct(_that.field0);case Size_FullClose() when fullClose != null:
return fullClose();case _:
  return null;

}
}

}

/// @nodoc


class Size_Usdt extends Size {
  const Size_Usdt(this.field0): super._();
  

 final  double field0;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Size_UsdtCopyWith<Size_Usdt> get copyWith => _$Size_UsdtCopyWithImpl<Size_Usdt>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size_Usdt&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'Size.usdt(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Size_UsdtCopyWith<$Res> implements $SizeCopyWith<$Res> {
  factory $Size_UsdtCopyWith(Size_Usdt value, $Res Function(Size_Usdt) _then) = _$Size_UsdtCopyWithImpl;
@useResult
$Res call({
 double field0
});




}
/// @nodoc
class _$Size_UsdtCopyWithImpl<$Res>
    implements $Size_UsdtCopyWith<$Res> {
  _$Size_UsdtCopyWithImpl(this._self, this._then);

  final Size_Usdt _self;
  final $Res Function(Size_Usdt) _then;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Size_Usdt(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class Size_Coin extends Size {
  const Size_Coin(this.field0): super._();
  

 final  double field0;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Size_CoinCopyWith<Size_Coin> get copyWith => _$Size_CoinCopyWithImpl<Size_Coin>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Size_Coin&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'Size.coin(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Size_CoinCopyWith<$Res> implements $SizeCopyWith<$Res> {
  factory $Size_CoinCopyWith(Size_Coin value, $Res Function(Size_Coin) _then) = _$Size_CoinCopyWithImpl;
@useResult
$Res call({
 double field0
});




}
/// @nodoc
class _$Size_CoinCopyWithImpl<$Res>
    implements $Size_CoinCopyWith<$Res> {
  _$Size_CoinCopyWithImpl(this._self, this._then);

  final Size_Coin _self;
  final $Res Function(Size_Coin) _then;

/// Create a copy of Size
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Size_Coin(
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
