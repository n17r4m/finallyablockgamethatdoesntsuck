//! Protobuf's wire encoding, written by hand: each field is a tag (field number and how its value
//! is written) and the value. A reader skips any field it doesn't know, which is what lets a
//! message grow without breaking anyone. Nothing here allocates except the `Vec` being written to.

pub const VARINT: u8 = 0;
pub const FIXED64: u8 = 1;
pub const BYTES: u8 = 2;
pub const FIXED32: u8 = 5;

/// Bytes a varint of `v` takes.
pub fn varint_len(v: u64) -> usize {
    (64 - (v | 1).leading_zeros() as usize).div_ceil(7)
}

pub fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

pub fn unzigzag(v: u64) -> i64 {
    ((v >> 1) as i64) ^ -((v & 1) as i64)
}

/// Writes fields onto the end of a Vec. Zero values are skipped, as protobuf does, so a field
/// that's usually 0 costs nothing.
pub struct Writer<'a> {
    pub out: &'a mut Vec<u8>,
}

impl Writer<'_> {
    pub fn raw_varint(&mut self, mut v: u64) {
        while v >= 0x80 {
            self.out.push(v as u8 | 0x80);
            v >>= 7;
        }
        self.out.push(v as u8);
    }

    fn tag(&mut self, field: u32, kind: u8) {
        self.raw_varint((field as u64) << 3 | kind as u64);
    }

    pub fn uint(&mut self, field: u32, v: u64) {
        if v != 0 {
            self.tag(field, VARINT);
            self.raw_varint(v);
        }
    }

    pub fn sint(&mut self, field: u32, v: i64) {
        self.uint(field, zigzag(v));
    }

    pub fn bool(&mut self, field: u32, v: bool) {
        self.uint(field, v as u64);
    }

    /// For values that are as likely to be big as small: seeds and hashes.
    pub fn fixed64(&mut self, field: u32, v: i64) {
        if v != 0 {
            self.tag(field, FIXED64);
            self.out.extend_from_slice(&v.to_le_bytes());
        }
    }

    pub fn bytes(&mut self, field: u32, v: &[u8]) {
        if !v.is_empty() {
            self.tag(field, BYTES);
            self.raw_varint(v.len() as u64);
            self.out.extend_from_slice(v);
        }
    }

    /// A nested message, whose size is known before it's written.
    pub fn message(&mut self, field: u32, size: usize, body: impl FnOnce(&mut Writer)) {
        self.tag(field, BYTES);
        self.raw_varint(size as u64);
        let start = self.out.len();
        body(self);
        debug_assert_eq!(self.out.len() - start, size, "nested message size");
    }

    /// Varints, packed into one field.
    pub fn packed(&mut self, field: u32, values: impl Iterator<Item = u64> + Clone) {
        let size: usize = values.clone().map(varint_len).sum();
        if size > 0 {
            self.tag(field, BYTES);
            self.raw_varint(size as u64);
            for v in values {
                self.raw_varint(v);
            }
        }
    }

    /// Fixed 64-bit values, packed into one field.
    pub fn packed_fixed64(&mut self, field: u32, values: impl ExactSizeIterator<Item = i64>) {
        if values.len() > 0 {
            self.tag(field, BYTES);
            self.raw_varint(values.len() as u64 * 8);
            for v in values {
                self.out.extend_from_slice(&v.to_le_bytes());
            }
        }
    }
}

/// Size of fields as `Writer` would write them, for nested messages.
pub fn uint_size(field: u32, v: u64) -> usize {
    if v == 0 { 0 } else { varint_len((field as u64) << 3) + varint_len(v) }
}

pub fn bytes_size(field: u32, len: usize) -> usize {
    if len == 0 { 0 } else { varint_len((field as u64) << 3) + varint_len(len as u64) + len }
}

/// One field's value as read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Value<'a> {
    Varint(u64),
    Fixed64(u64),
    Bytes(&'a [u8]),
    Fixed32(u32),
}

impl<'a> Value<'a> {
    pub fn uint(self) -> Option<u64> {
        match self {
            Value::Varint(v) => Some(v),
            _ => None,
        }
    }
    pub fn sint(self) -> Option<i64> {
        self.uint().map(unzigzag)
    }
    pub fn fixed64(self) -> Option<i64> {
        match self {
            Value::Fixed64(v) => Some(v as i64),
            _ => None,
        }
    }
    pub fn bytes(self) -> Option<&'a [u8]> {
        match self {
            Value::Bytes(b) => Some(b),
            _ => None,
        }
    }
    pub fn text(self) -> Option<&'a str> {
        std::str::from_utf8(self.bytes()?).ok()
    }
}

/// Reads fields one at a time. Any damage ends it: `next` returns `Err` and the message is
/// thrown away.
pub struct Reader<'a> {
    pub b: &'a [u8],
}

impl<'a> Reader<'a> {
    pub fn new(b: &'a [u8]) -> Reader<'a> {
        Reader { b }
    }

    pub fn raw_varint(&mut self) -> Option<u64> {
        let mut v = 0u64;
        for k in 0..10 {
            let byte = *self.b.get(k)?;
            v |= ((byte & 0x7f) as u64) << (7 * k);
            if byte < 0x80 {
                // The tenth byte can only hold the top bit.
                if k == 9 && byte > 1 {
                    return None;
                }
                self.b = &self.b[k + 1..];
                return Some(v);
            }
        }
        None
    }

    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.b.len() < n {
            return None;
        }
        let (head, rest) = self.b.split_at(n);
        self.b = rest;
        Some(head)
    }

    pub fn done(&self) -> bool {
        self.b.is_empty()
    }

    /// The next field, None at the end, Err(()) if the bytes are damaged.
    #[allow(clippy::should_implement_trait, clippy::result_unit_err)]
    pub fn next(&mut self) -> Result<Option<(u32, Value<'a>)>, ()> {
        if self.b.is_empty() {
            return Ok(None);
        }
        let tag = self.raw_varint().ok_or(())?;
        let field = u32::try_from(tag >> 3).map_err(|_| ())?;
        if field == 0 {
            return Err(());
        }
        let value = match (tag & 7) as u8 {
            VARINT => Value::Varint(self.raw_varint().ok_or(())?),
            FIXED64 => Value::Fixed64(u64::from_le_bytes(self.take(8).ok_or(())?.try_into().unwrap())),
            BYTES => {
                let n = usize::try_from(self.raw_varint().ok_or(())?).map_err(|_| ())?;
                Value::Bytes(self.take(n).ok_or(())?)
            }
            FIXED32 => Value::Fixed32(u32::from_le_bytes(self.take(4).ok_or(())?.try_into().unwrap())),
            _ => return Err(()),
        };
        Ok(Some((field, value)))
    }
}

/// Reads packed varints.
pub struct Packed<'a>(Reader<'a>);

impl<'a> Packed<'a> {
    pub fn new(b: &'a [u8]) -> Packed<'a> {
        Packed(Reader::new(b))
    }
}

impl Iterator for Packed<'_> {
    type Item = Option<u64>;
    fn next(&mut self) -> Option<Option<u64>> {
        if self.0.done() { None } else { Some(self.0.raw_varint()) }
    }
}
