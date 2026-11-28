/* Optional OpenSSL backend for public secp256k1/r1 syscall operands. The
   caller has checked the coordinates and the scalar is an unsigned u256. */
#include <caml/mlvalues.h>
#ifdef OXC_HAVE_OPENSSL
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/obj_mac.h>
#endif

value cvm_secp_curve_available(value unit) {
  (void)unit;
#ifdef OXC_HAVE_OPENSSL
  return Val_true;
#else
  return Val_false;
#endif
}

/* Return 1 for affine coordinates, 0 for infinity and -1 for an unavailable
   operation. Allocation failures can use the portable implementation. */
value cvm_secp_curve_scale(value r1, value x, value y, value scalar, value output) {
#ifdef OXC_HAVE_OPENSSL
  if (caml_string_length(x) > 32 || caml_string_length(y) > 32 ||
      caml_string_length(scalar) > 32 || caml_string_length(output) != 64)
    return Val_int(-1);
  BN_CTX *ctx = BN_CTX_new();
  EC_GROUP *group = EC_GROUP_new_by_curve_name(Bool_val(r1) ? NID_X9_62_prime256v1 : NID_secp256k1);
  EC_POINT *point = group ? EC_POINT_new(group) : NULL;
  int status = -1;
  if (ctx && point) {
    BN_CTX_start(ctx);
    BIGNUM *a = BN_CTX_get(ctx), *b = BN_CTX_get(ctx), *k = BN_CTX_get(ctx);
    if (k && BN_lebin2bn((const unsigned char *)String_val(x), caml_string_length(x), a) &&
        BN_lebin2bn((const unsigned char *)String_val(y), caml_string_length(y), b) &&
        BN_lebin2bn((const unsigned char *)String_val(scalar), caml_string_length(scalar), k) &&
        EC_POINT_set_affine_coordinates(group, point, a, b, ctx) &&
        EC_POINT_mul(group, point, NULL, point, k, ctx)) {
      if (EC_POINT_is_at_infinity(group, point)) status = 0;
      else if (EC_POINT_get_affine_coordinates(group, point, a, b, ctx) &&
               BN_bn2lebinpad(a, (unsigned char *)Bytes_val(output), 32) == 32 &&
               BN_bn2lebinpad(b, (unsigned char *)Bytes_val(output) + 32, 32) == 32)
        status = 1;
    }
    BN_CTX_end(ctx);
  }
  EC_POINT_free(point);
  EC_GROUP_free(group);
  BN_CTX_free(ctx);
  return Val_int(status);
#else
  (void)r1; (void)x; (void)y; (void)scalar; (void)output;
  return Val_int(-1);
#endif
}
