=head1 NAME

Compress::LZF - extremely leight-weight Lev-Zimpel-Free compression

=head1 SYNOPSIS

   use Compress::LZF;

   $compressed = compress $uncompressed_data;

   $original_data = decompress $compressed;

=head1 DESCRIPTION

LZF is an extremely fast (not that much slower than a pure memcpy)
compression algorithm. It is ideal for applications where you want to save
I<some> space but not at the cost of speed. It is ideal for repetitive
data as well. The module is self-contained and very small (no large
library to be pulled in). It is also free, so there should be no problems
incoporating this module into commercial programs.

I have no idea wether any patents in any countries apply to this
algorithm, but at the moment it is believed that it is free from any
patents.

=head1 FUNCTIONS

=head2 $compressed = compress $uncompressed

Try to compress the given string as quickly and as much as possible. In
the worst case, the string can enlarge by 1 byte, but that should be the
absolute exception. You can expect a 45% compression ratio on large,
binary strings.

=head2 $decompressed = decompress $compressed

Uncompress the string (compressed by C<compress>) and return the original
data. Decompression errors can result in either broken data (there is no
checksum kept) or a runtime error.

=head1 SEE ALSO

Other Compress::* modules, especially Compress::LZV1 (an older, less
speedy module that guarentees only 1 byte overhead worst case) and
Compress::Zlib.

http://liblzf.plan9.de/

=head1 AUTHOR

This perl extension and the underlying liblzf were written by Marc Lehmann
<pcg@goof.com> (See also http://liblzf.plan9.de/).

=head1 BUGS

=cut

package Compress::LZF;

require Exporter;
require DynaLoader;

$VERSION = 0.05;
@ISA = qw/Exporter DynaLoader/;
@EXPORT = qw(compress decompress);
bootstrap Compress::LZF $VERSION;

1;





