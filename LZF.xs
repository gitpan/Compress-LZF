#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* try to be compatible with older perls */
/* SvPV_nolen() macro first defined in 5.005_55 */
/* this is slow, not threadsafe, but works */
#include "patchlevel.h"
#if (PATCHLEVEL == 4) || ((PATCHLEVEL == 5) && (SUBVERSION < 55))
static STRLEN nolen_na;
# define SvPV_nolen(sv) SvPV ((sv), nolen_na)
#endif
#if PATCHLEVEL < 6
# define call_sv perl_call_sv
#endif

#include "lzf_c.c"
#include "lzf_d.c"

/* we re-use the storable header for our purposes */
#define MAGIC_LO	0
#define MAGIC_U		0 /* uncompressed data follows */
#define MAGIC_C		1 /* compressed data follows */
#define MAGIC_undef	2 /* the special value undef */
#define MAGIC_CR	3 /* storable (reference, freeze), compressed */
#define MAGIC_R		4 /* storable (reference, freeze) */
#define MAGIC_HI	7 /* room for one higher storable major */

#define IN_RANGE(v,l,h) ((unsigned int)((unsigned)(v) - (unsigned)(l)) <= (unsigned)(h) - (unsigned)(l))

static CV *storable_mstore, *storable_mretrieve;

static SV *
compress_sv (SV *data, char cprepend, char uprepend)
{
  STRLEN usize, csize;
  char *src = (char *)SvPV (data, usize);

  if (usize)
    {
      SV *ret = NEWSV (0, usize + 1);
      unsigned char *dst;
      int skip = 0;

      SvPOK_only (ret);
      dst = (unsigned char *)SvPVX (ret);

      if (cprepend)
        dst[skip++] = cprepend;

      if (usize < 0x80)
        {
          dst[skip++] = usize;
        }
      else if (usize < 0x800) 
        {
          dst[skip++] = (( usize >>  6)         | 0xc0);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize < 0x10000) 
        {
          dst[skip++] = (( usize >> 12)         | 0xe0);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize < 0x200000) 
        {
          dst[skip++] = (( usize >> 18)         | 0xf0);
          dst[skip++] = (((usize >> 12) & 0x3f) | 0x80);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize < 0x4000000) 
        {
          dst[skip++] = (( usize >> 24)         | 0xf8);
          dst[skip++] = (((usize >> 18) & 0x3f) | 0x80);
          dst[skip++] = (((usize >> 12) & 0x3f) | 0x80);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else
        croak ("compress can only compress up to %ld bytes", 0x4000000-1);

      /* 11 bytes is the smallest compressible string */
      csize = usize < 11 ? 0 :
              lzf_compress (src, usize,
                                  dst + skip,
                                  usize - skip);

      if (csize)
        {
          SvCUR_set (ret, csize + skip);
        }
      else if (!uprepend)
        {
          SvREFCNT_dec (ret);
          ret = SvREFCNT_inc (data);
        }
      else
        {
          *dst++ = 0;

          Move ((void *)src, (void *)dst, usize, unsigned char);

          SvCUR_set (ret, usize + 1);
        }

      return ret;
    }
  else
    return newSVpv ("", 0);
}

static SV *
decompress_sv (SV *data, int skip)
{
  STRLEN usize, csize;
  unsigned char *src = (unsigned char *)SvPV (data, csize) + skip;

  if (csize)
    {
      void *dst;
      SV *ret;

      csize -= skip;

      if (src[0])
        {
          if (!(src[0] & 0x80))
            {
              csize -= 1;
              usize =                 *src++ & 0xff;
            }
          else if (!(src[0] & 0x20))
            {
              csize -= 2;
              usize =                 *src++ & 0x1f;
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x10))
            {
              csize -= 3;
              usize =                 *src++ & 0x0f;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x08))
            {
              csize -= 4;
              usize =                 *src++ & 0x07;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x04))
            {
              csize -= 5;
              usize =                 *src++ & 0x03;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else
            croak ("compressed data corrupted");
                    
          ret = NEWSV (0, usize);
          SvPOK_only (ret);
          dst = SvPVX (ret);

          if (lzf_decompress (src, csize, dst, usize) != usize)
            croak ("compressed data corrupted", csize, skip, usize);
        }
      else
        {
          usize = csize - 1;
          ret = NEWSV (0, usize);
          SvPOK_only (ret);

          Move ((void *)(src + 1), (void *)SvPVX (ret), usize, unsigned char);
      }

      SvCUR_set (ret, usize);

      return ret;
    }
  else
    return newSVpvn ("", 0);
}

static void
need_storable(void)
{
#if PATCHLEVEL < 6
  perl_eval_pv ("require Storable;", 1);
#else
  load_module (PERL_LOADMOD_NOIMPORT, newSVpv ("Storable", 0), Nullsv);
#endif

  storable_mstore    = GvCV (gv_fetchpv ("Storable::mstore"   , TRUE, SVt_PVCV));
  storable_mretrieve = GvCV (gv_fetchpv ("Storable::mretrieve", TRUE, SVt_PVCV));
}

MODULE = Compress::LZF   PACKAGE = Compress::LZF

void
compress(data)
        SV *	data
        PROTOTYPE: $
        PPCODE:
        XPUSHs (sv_2mortal (compress_sv (data, 0, 1)));

void
decompress(data)
        SV *	data
        PROTOTYPE: $
        PPCODE:
        XPUSHs (sv_2mortal (decompress_sv (data, 0)));

void
sfreeze(sv)
	SV *	sv
        ALIAS:
        sfreeze_cr = 1
        sfreeze_c  = 2
        PROTOTYPE: $
        PPCODE:

        if (!SvOK (sv))
          XPUSHs (sv_2mortal (newSVpvn ("\02", 1))); /* 02 == MAGIC_undef */
        else if (SvTYPE(sv) != SVt_IV
            && SvTYPE(sv) != SVt_NV
            && SvTYPE(sv) != SVt_PV) /* mstore */
          {
            if (!storable_mstore)
              need_storable ();

            PUSHMARK (SP);
            XPUSHs (sv);
            PUTBACK;

            if (1 != call_sv ((SV *)storable_mstore, G_SCALAR))
              croak ("Storable::mstore didn't return a single scalar");

            SPAGAIN;

            sv = POPs;

            if (SvPVX (sv)[0] != MAGIC_R)
              croak ("Storable format changed, need newer version of Compress::LZF");

            if (ix) /* compress */
              XPUSHs (sv_2mortal (compress_sv (sv, MAGIC_CR, 0)));
            else
              XPUSHs (sv);
          }
        else if (sv && IN_RANGE (SvPVX (sv)[0], MAGIC_LO, MAGIC_HI))
          XPUSHs (sv_2mortal (compress_sv (sv, MAGIC_C, 1))); /* need to prefix only */
        else if (ix == 2) /* compress always */
          XPUSHs (sv_2mortal (compress_sv (sv, MAGIC_C, 0)));
        else /* don't compress */
          XPUSHs (sv_2mortal (SvREFCNT_inc (sv)));

void
sthaw(sv)
	SV *	sv
        PROTOTYPE: $
        PPCODE:

        SvGETMAGIC (sv);
        if (SvPOK (sv) && IN_RANGE (SvPV_nolen (sv)[0], MAGIC_LO, MAGIC_HI))
          {
            switch (SvPVX (sv)[0])
              {
                case MAGIC_undef:
                  XPUSHs (sv_2mortal (NEWSV (0, 0)));
                  break;

                case MAGIC_U:
                  XPUSHs (sv_2mortal (decompress_sv (sv, 0)));
                  break;

                case MAGIC_C:
                  XPUSHs (sv_2mortal (decompress_sv (sv, 1)));
                  break;

                case MAGIC_CR:
                  sv = sv_2mortal (decompress_sv (sv, 1)); /* mortal could be optimized */
                case MAGIC_R:
                  if (!storable_mstore)
                    need_storable ();

                  PUSHMARK (SP);
                  XPUSHs (sv);
                  PUTBACK;

                  if (1 != call_sv ((SV *)storable_mretrieve, G_SCALAR))
                    croak ("Storable::mstore didn't return a single scalar");

                  SPAGAIN;

                  /*XPUSHs (POPs); this is a nop, hopefully */

                  break; 

                default:
                  croak ("Compress::LZF::sthaw(): invalid data, maybe you need a newer version of Compress::LZF?");
              }
          }
        else
          XPUSHs (sv_2mortal (SvREFCNT_inc (sv)));
