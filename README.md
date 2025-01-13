# Zig PieceTable

## Overview

A piece table is made of two buffers, the original content and a new append only "add" buffer.
We start with a "span" that covers the entire original buffer, and for every modification we
divide that up based on where hte insert or delete is performed and how many characters it is.

Each of these operations represented as new spans are made into the new "add" buffer, leaving
the original as is. Each piece or span therefore references three things:

1. Is it referencing original content or new content (i.e. original or add buffer)
2. The offset to the start of the change
3. Number of bytes that are being changed after the offset.

Spans are listed in order in a table (hence piece table), which can be traversed from top to
bottom for a consistent history of changes.

## Usage

To use in your Zig project, pick a commit hash you want to use and run the following,
replacing `<hash>` with the commit hash:

```bash
zig fetch --save=piecetable https://github.com/daurnimator/zig-piecetable/archive/<hash>.tar.gz
```

## References

* https://en.wikipedia.org/wiki/Piece_table
* https://www.averylaird.com/programming/the%20text%20editor/2017/09/30/the-piece-table/
