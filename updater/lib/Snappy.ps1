# Snappy raw-block decompressor (format spec: github.com/google/snappy/blob/main/format_description.txt)
# GitHub serves attestation bundles (bundle_url) as snappy raw blocks. PowerShell 5.1 compatible (Add-Type C#).
# Hard output cap guards against decompression bombs from a hostile/tampered response.

Set-StrictMode -Version Latest

if (-not ('MlUpdater.Snappy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
namespace MlUpdater {
    public static class Snappy {
        public static byte[] Decode(byte[] src, int maxOut) {
            if (src == null) throw new ArgumentNullException("src");
            int pos = 0;
            long ulen = 0; int shift = 0;
            while (true) {
                if (pos >= src.Length || shift > 28) throw new FormatException("bad snappy length varint");
                byte b = src[pos++];
                ulen |= (long)(b & 0x7F) << shift;
                if ((b & 0x80) == 0) break;
                shift += 7;
            }
            if (ulen > maxOut) throw new FormatException("snappy output exceeds cap");
            byte[] dst = new byte[ulen];
            int d = 0;
            while (pos < src.Length) {
                int tag = src[pos++];
                int kind = tag & 3;
                if (kind == 0) {
                    int len = (tag >> 2) + 1;
                    if (len > 60) {
                        int extra = len - 60;
                        if (pos + extra > src.Length) throw new FormatException("truncated literal length");
                        len = 0;
                        for (int i = 0; i < extra; i++) len |= src[pos++] << (8 * i);
                        len += 1;
                    }
                    if (len < 0 || pos + len > src.Length || d + len > dst.Length) throw new FormatException("bad literal");
                    Buffer.BlockCopy(src, pos, dst, d, len);
                    pos += len; d += len;
                } else {
                    int len, off;
                    if (kind == 1) {
                        if (pos + 1 > src.Length) throw new FormatException("truncated copy1");
                        len = 4 + ((tag >> 2) & 7);
                        off = ((tag >> 5) << 8) | src[pos++];
                    } else if (kind == 2) {
                        if (pos + 2 > src.Length) throw new FormatException("truncated copy2");
                        len = 1 + (tag >> 2);
                        off = src[pos] | (src[pos + 1] << 8); pos += 2;
                    } else {
                        if (pos + 4 > src.Length) throw new FormatException("truncated copy4");
                        len = 1 + (tag >> 2);
                        long o = (long)src[pos] | ((long)src[pos + 1] << 8) | ((long)src[pos + 2] << 16) | ((long)src[pos + 3] << 24);
                        pos += 4;
                        if (o > int.MaxValue) throw new FormatException("bad offset");
                        off = (int)o;
                    }
                    if (off <= 0 || off > d || d + len > dst.Length) throw new FormatException("bad copy");
                    for (int i = 0; i < len; i++) { dst[d] = dst[d - off]; d++; }
                }
            }
            if (d != dst.Length) throw new FormatException("snappy length mismatch");
            return dst;
        }
    }
}
'@
}

function ConvertFrom-SnappyBlock {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [int]$MaxOutputBytes = 4MB
    )
    return , [MlUpdater.Snappy]::Decode($Bytes, $MaxOutputBytes)
}
