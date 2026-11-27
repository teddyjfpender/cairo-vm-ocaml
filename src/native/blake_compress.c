/* BLAKE2s compression, RFC 7693 section 3.2. Constant message indices
   let the compiler keep the round state in registers. */
#include <caml/mlvalues.h>
#include <stdint.h>

static inline uint32_t rotate(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32 - n));
}

#define MIX(a,b,c,d,x,y) do { \
  a += b + x; d = rotate(d ^ a, 16); c += d; b = rotate(b ^ c, 12); \
  a += b + y; d = rotate(d ^ a, 8); c += d; b = rotate(b ^ c, 7); \
} while (0)

#define ROUND(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) do { \
  MIX(v[0],v[4],v[8],v[12],words[a],words[b]); \
  MIX(v[1],v[5],v[9],v[13],words[c],words[d]); \
  MIX(v[2],v[6],v[10],v[14],words[e],words[f]); \
  MIX(v[3],v[7],v[11],v[15],words[g],words[h]); \
  MIX(v[0],v[5],v[10],v[15],words[i],words[j]); \
  MIX(v[1],v[6],v[11],v[12],words[k],words[l]); \
  MIX(v[2],v[7],v[8],v[13],words[m],words[n]); \
  MIX(v[3],v[4],v[9],v[14],words[o],words[p]); \
} while (0)

CAMLprim value cvm_blake2s(value state, value msg, value t0, value t1, value f0, value f1) {
  static const uint32_t iv[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                                 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  uint32_t v[16], words[16];
  for (unsigned i = 0; i < 8; i++) {
    v[i] = Long_val(Field(state, i));
    v[i+8] = iv[i];
  }
  for (unsigned i = 0; i < 16; i++) words[i] = Long_val(Field(msg, i));
  v[12] ^= Long_val(t0); v[13] ^= Long_val(t1);
  v[14] ^= Long_val(f0); v[15] ^= Long_val(f1);
  ROUND(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);
  ROUND(14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3);
  ROUND(11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4);
  ROUND(7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8);
  ROUND(9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13);
  ROUND(2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9);
  ROUND(12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11);
  ROUND(13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10);
  ROUND(6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5);
  ROUND(10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0);
  for (unsigned i = 0; i < 8; i++)
    Field(state, i) = Val_long((uint32_t)Long_val(Field(state,i)) ^ v[i] ^ v[i+8]);
  return Val_unit;
}

CAMLprim value cvm_blake2s_byte(value *argv, int argc) {
  (void)argc;
  return cvm_blake2s(argv[0],argv[1],argv[2],argv[3],argv[4],argv[5]);
}
