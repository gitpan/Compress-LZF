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

#include "lzf_c.c"
#include "lzf_d.c"

MODULE = Compress::LZF   PACKAGE = Compress::LZF

void
compress(data)
        SV *	data
        PROTOTYPE: $
        PPCODE:
        {
          STRLEN usize, csize;
          void *src = SvPV (data, usize);
          unsigned char *dst;
          SV *ret;

          if (usize)
            {
              int skip;

              ret = NEWSV (0, usize + 1);
              SvPOK_only (ret);
              dst = (unsigned char *)SvPVX (ret);

              if (usize < 0x80)
                {
                  skip = 1;
                  dst[0] = usize;
                }
              else if (usize < 0x800) 
                {
                  skip = 2;
                  dst[0] = (( usize >>  6)         | 0xc0);
                  dst[1] = (( usize        & 0x3f) | 0x80);
                }
              else if (usize < 0x10000) 
                {
                  skip = 3;
                  dst[0] = (( usize >> 12)         | 0xe0);
                  dst[1] = (((usize >>  6) & 0x3f) | 0x80);
                  dst[2] = (( usize        & 0x3f) | 0x80);
                }
              else if (usize < 0x200000) 
                {
                  skip = 4;
                  dst[0] = (( usize >> 18)         | 0xf0);
                  dst[1] = (((usize >> 12) & 0x3f) | 0x80);
                  dst[2] = (((usize >>  6) & 0x3f) | 0x80);
                  dst[3] = (( usize        & 0x3f) | 0x80);
                }
              else if (usize < 0x4000000) 
                {
                  skip = 5;
                  dst[0] = (( usize >> 24)         | 0xf8);
                  dst[1] = (((usize >> 18) & 0x3f) | 0x80);
                  dst[2] = (((usize >> 12) & 0x3f) | 0x80);
                  dst[3] = (((usize >>  6) & 0x3f) | 0x80);
                  dst[4] = (( usize        & 0x3f) | 0x80);
                }
              else
                croak ("compress can only compress up to %ld bytes", 0x4000000-1);

              csize = lzf_compress (src, usize, dst + skip, usize - skip - 1);

              if (csize)
                {
                  SvCUR_set (ret, csize + skip);
                }
              else
                {
                  *dst++ = 0;
                  Move ((void *)src, (void *)dst, usize, unsigned char);

                  SvCUR_set (ret, usize + 1);
                }
            }
          else
            ret = newSVpv ("", 0);

          XPUSHs (sv_2mortal (ret));
        }

void
decompress(data)
        SV *	data
        PROTOTYPE: $
        PPCODE:
        {
          STRLEN usize, csize;
          unsigned char *src = (unsigned char *)SvPV (data, csize);
          void *dst;
          SV *ret;

          if (csize)
            {
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
                    croak ("compressed data corrupted");
                }
              else
                {
                  usize = csize - 1;
                  ret = NEWSV (0, usize);
                  SvPOK_only (ret);

                  Move ((void *)(src + 1), (void *)SvPVX (ret), usize, unsigned char);
              }

              SvCUR_set (ret, usize);
            }
          else
            ret = newSVpvn ("", 0);

          XPUSHs (sv_2mortal (ret));
        }

