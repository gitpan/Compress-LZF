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

#define LZF_STANDALONE 1
#define LZF_STATE_ARG 1

#include "lzf_c.c"
#include "lzf_d.c"

/* we re-use the storable header for our purposes */
#define MAGIC_LO	0
#define MAGIC_U		0 /* uncompressed data follows */
#define MAGIC_C		1 /* compressed data follows */
#define MAGIC_undef	2 /* the special value undef */
#define MAGIC_CR	3 /* storable (reference, freeze), compressed */
#define MAGIC_R		4 /* storable (reference, freeze) */
#define MAGIC_CR_deref	5 /* storable (NO reference, freeze), compressed */
#define MAGIC_R_deref	6 /* storable (NO reference, freeze) */
#define MAGIC_HI	7 /* room for one higher storable major */
/* for historical reasons, MAGIC_undef + MAGIC_R and MAGIC_undef + MAGIC_R_deref are used, too */

#define IN_RANGE(v,l,h) ((unsigned int)((unsigned)(v) - (unsigned)(l)) <= (unsigned)(h) - (unsigned)(l))

static SV *serializer_package, *serializer_mstore, *serializer_mretrieve;
static CV *storable_mstore, *storable_mretrieve;

#if Size_t_size > 4
# define MAX_LENGTH ((Size_t)0x80000000L)
#else
# define MAX_LENGTH ((Size_t) 0x8000000L)
#endif

static SV *
compress_sv (SV *data, char cprepend, int uprepend)
{
  LZF_STATE *state;
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

      if (usize <= 0x7f)
        {
          dst[skip++] = usize;
        }
      else if (usize <= 0x7ff) 
        {
          dst[skip++] = (( usize >>  6)         | 0xc0);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize <= 0xffff) 
        {
          dst[skip++] = (( usize >> 12)         | 0xe0);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize <= 0x1fffff) 
        {
          dst[skip++] = (( usize >> 18)         | 0xf0);
          dst[skip++] = (((usize >> 12) & 0x3f) | 0x80);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize <= 0x3ffffff) 
        {
          dst[skip++] = (( usize >> 24)         | 0xf8);
          dst[skip++] = (((usize >> 18) & 0x3f) | 0x80);
          dst[skip++] = (((usize >> 12) & 0x3f) | 0x80);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else if (usize <= 0x7fffffff) 
        {
          dst[skip++] = (( usize >> 30)         | 0xfc);
          dst[skip++] = (((usize >> 24) & 0x3f) | 0x80);
          dst[skip++] = (((usize >> 18) & 0x3f) | 0x80);
          dst[skip++] = (((usize >> 12) & 0x3f) | 0x80);
          dst[skip++] = (((usize >>  6) & 0x3f) | 0x80);
          dst[skip++] = (( usize        & 0x3f) | 0x80);
        }
      else
        croak ("compress can only compress up to %ld bytes", 0x7fffffffL);

      New (0, state, 1, LZF_STATE);
      if (!state)
        croak ("Compress::LZF unable to allocate memory for compression state");

      /* 11 bytes is the smallest compressible string */
      csize = usize < 11 ? 0 :
              lzf_compress (src, usize, dst + skip, usize - skip, *state);

      Safefree (state);

      if (csize)
        {
          SvCUR_set (ret, csize + skip);
        }
      else if (uprepend < 0)
        {
          SvREFCNT_dec (ret);
          ret = SvREFCNT_inc (data);
        }
      else
        {
          *dst++ = uprepend;

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
          if (!(src[0] & 0x80) && csize >= 1)
            {
              csize -= 1;
              usize =                 *src++ & 0xff;
            }
          else if (!(src[0] & 0x20) && csize >= 2)
            {
              csize -= 2;
              usize =                 *src++ & 0x1f;
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x10) && csize >= 3)
            {
              csize -= 3;
              usize =                 *src++ & 0x0f;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x08) && csize >= 4)
            {
              csize -= 4;
              usize =                 *src++ & 0x07;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x04) && csize >= 5)
            {
              csize -= 5;
              usize =                 *src++ & 0x03;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else if (!(src[0] & 0x02) && csize >= 6)
            {
              csize -= 6;
              usize =                 *src++ & 0x01;
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
              usize = (usize << 6) | (*src++ & 0x3f);
            }
          else
            croak ("compressed data corrupted (invalid length)");

          if (!usize)
            croak ("compressed data corrupted (invalid length)");
                    
          ret = NEWSV (0, usize);
          SvPOK_only (ret);
          dst = SvPVX (ret);

          if (lzf_decompress (src, csize, dst, usize) != usize)
            {
              SvREFCNT_dec (ret);
              croak ("compressed data corrupted (size mismatch)", csize, skip, usize);
            }
        }
      else
        {
          usize = csize - 1;
          ret = NEWSV (0, usize | 1);
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
  char req[8192];
  sprintf (req, "require %s;", SvPV_nolen (serializer_package));
  perl_eval_pv (req, 1);
#else
  load_module (PERL_LOADMOD_NOIMPORT, serializer_package, Nullsv);
#endif

  storable_mstore    = GvCV (gv_fetchpv (SvPV_nolen (serializer_mstore   ), TRUE, SVt_PVCV));
  storable_mretrieve = GvCV (gv_fetchpv (SvPV_nolen (serializer_mretrieve), TRUE, SVt_PVCV));
}

MODULE = Compress::LZF   PACKAGE = Compress::LZF

BOOT:
        serializer_package   = newSVpv ("Storable", 0);
        serializer_mstore    = newSVpv ("Storable::net_mstore", 0);
        serializer_mretrieve = newSVpv ("Storable::mretrieve", 0);

void
set_serializer(package, mstore, mretrieve)
	SV *	package
	SV *	mstore
	SV *	mretrieve
        PROTOTYPE: $$$
        PPCODE:
        SvSetSV (serializer_package  , package  );
        SvSetSV (serializer_mstore   , mstore   );
        SvSetSV (serializer_mretrieve, mretrieve);
        storable_mstore =
        storable_mretrieve = 0;

void
compress(data)
        SV *	data
        PROTOTYPE: $
        PPCODE:
        XPUSHs (sv_2mortal (compress_sv (data, 0, MAGIC_U)));

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

        SvGETMAGIC (sv);

        if (!SvOK (sv))
          XPUSHs (sv_2mortal (newSVpvn ("\02", 1))); /* 02 == MAGIC_undef */
        else if (SvROK (sv)
              || (SvTYPE(sv) != SVt_IV
                 && SvTYPE(sv) != SVt_NV
                 && SvTYPE(sv) != SVt_PV
                 && SvTYPE(sv) != SVt_PVIV
                 && SvTYPE(sv) != SVt_PVNV
                 && SvTYPE(sv) != SVt_PVMG)) /* mstore */
          {
            int deref = !SvROK (sv);

            if (!storable_mstore)
              need_storable ();

            if (deref)
              sv = newRV_noinc (sv);

            PUSHMARK (SP);
            XPUSHs (sv);
            PUTBACK;

            if (1 != call_sv ((SV *)storable_mstore, G_SCALAR))
              croak ("Storable::mstore didn't return a single scalar");

            SPAGAIN;

            sv = POPs;

            if (SvPVX (sv)[0] == MAGIC_R)
              {
                if (deref)
                  SvPVX (sv)[0] = MAGIC_R_deref;
              }
            else
              {
                char pfx[2];

                pfx[0] = MAGIC_undef;
                pfx[1] = deref ? MAGIC_R_deref : MAGIC_R;

                sv_insert (sv, 0, 0, pfx, 2);
              }

            if (ix) /* compress */
              sv = sv_2mortal (compress_sv (sv, deref ? MAGIC_CR_deref : MAGIC_CR, -1));

            XPUSHs (sv);
          }
        else if (SvPOKp (sv) && IN_RANGE (SvPVX (sv)[0], MAGIC_LO, MAGIC_HI))
          XPUSHs (sv_2mortal (compress_sv (sv, MAGIC_C, MAGIC_U))); /* need to prefix only */
        else if (ix == 2) /* compress always */
          XPUSHs (sv_2mortal (compress_sv (sv, MAGIC_C, -1)));
        else if (SvNIOK (sv)) /* don't compress */
          {
            STRLEN len;
            char *s = SvPV (sv, len);
            XPUSHs (sv_2mortal (newSVpvn (s, len)));
          }
        else /* don't compress */
          XPUSHs (sv_2mortal (newSVsv (sv)));

void
sthaw(sv)
	SV *	sv
        PROTOTYPE: $
        PPCODE:
{
        STRLEN svlen;
        int deref = 0;

        SvGETMAGIC (sv);
        if (SvPOK (sv) && IN_RANGE (SvPV (sv, svlen)[0], MAGIC_LO, MAGIC_HI))
          {
            redo:

            switch (SvPVX (sv)[0])
              {
                case MAGIC_undef:
                  if (svlen <= 1)
                    XPUSHs (sv_2mortal (NEWSV (0, 0)));
                  else
                    {
                      if (SvPVX (sv)[1] == MAGIC_R_deref)
                        deref = 1;
                      else if (SvPVX (sv)[1] != MAGIC_R)
                        croak ("Compress::LZF::sthaw(): invalid data, maybe you need a newer version of Compress::LZF?");

                      sv_chop (sv, SvPVX (sv) + 2);

                      if (!storable_mstore)
                        need_storable ();

                      PUSHMARK (SP);
                      XPUSHs (sv);
                      PUTBACK;

                      if (1 != call_sv ((SV *)storable_mretrieve, G_SCALAR))
                        croak ("Storable::mstore didn't return a single scalar");

                      SPAGAIN;

                      if (deref)
                        SETs (sv_2mortal (SvREFCNT_inc (SvRV (TOPs))));
                      else
                        SETs (sv_2mortal (newSVsv (TOPs)));
                    }
                  break;

                case MAGIC_U:
                  XPUSHs (sv_2mortal (decompress_sv (sv, 0)));
                  break;

                case MAGIC_C:
                  XPUSHs (sv_2mortal (decompress_sv (sv, 1)));
                  break;

                case MAGIC_R_deref:
                  deref = 1;
                  SvPVX (sv)[0] = MAGIC_R;
                  goto handle_MAGIC_R;

                case MAGIC_CR_deref:
                  deref = 1;
                case MAGIC_CR:
                  sv = sv_2mortal (decompress_sv (sv, 1)); /* mortal could be optimized */
                  if (deref)
                    if (SvPVX (sv)[0] == MAGIC_R_deref)
                      SvPVX (sv)[0] = MAGIC_R;

                  goto redo;

                case MAGIC_R:
                handle_MAGIC_R:
                  if (!storable_mstore)
                    need_storable ();

                  PUSHMARK (SP);
                  XPUSHs (sv);
                  PUTBACK;

                  if (1 != call_sv ((SV *)storable_mretrieve, G_SCALAR))
                    croak ("Storable::mstore didn't return a single scalar");

                  SPAGAIN;

                  if (deref)
                    {
                      SETs (sv_2mortal (SvREFCNT_inc (SvRV (TOPs))));

                      if (SvPVX (sv)[0] == MAGIC_R)
                        SvPVX (sv)[0] = MAGIC_R_deref;
                    }
                  else
                    SETs (sv_2mortal (newSVsv (TOPs)));

                  break; 

                default:
                  croak ("Compress::LZF::sthaw(): invalid data, maybe you need a newer version of Compress::LZF?");
              }
          }
        else
          XPUSHs (sv_2mortal (newSVsv (sv)));
}

