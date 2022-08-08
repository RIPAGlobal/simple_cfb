# frozen_string_literal: true

require 'ostruct'
require 'date'
require 'stringio'
require 'active_support/core_ext/object/blank.rb'
require 'active_support/core_ext/object/try.rb'

# Ported from https://github.com/SheetJS/js-cfb.
#
# File data is added with #add then, when finished, the entire blob of CFB
# data is generated in one go with #write. Progressive creation is impossible
# as the CFB file requires information on file sizes and directory entries at
# the start of output, so all of that must be known beforehand.
#
# Files can be parsed into a new object with #parse!, then #file_index and
# #full_paths examined to extract the parsed CFB container components.
#
#    https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/
#
# This Ruby port tries to be equivalent to the JavaScript original, but in so
# doing there are likely additional bugs and I've omitted anything that wasn't
# needed for encrypted OOXML writing and reading.
#
class SimpleCfb

  # CFB miscellaneous
  #
  MSSZ  = 64   # Mini Sector Size = 1<<6
  MSCSZ = 4096 # Mini Stream Cutoff Size

  # Convenience accessor to binary-encoded NUL byte.
  #
  NUL = String.new("\x00", encoding: 'ASCII-8BIT')

  # 2.1 Compound File Sector Numbers and Types
  #
  FREESECT   = -1
  ENDOFCHAIN = -2
  FATSECT    = -3
  DIFSECT    = -4
  MAXREGSECT = -6

  # Compound File Header
  #
  HEADER_SIGNATURE     = String.new("\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1", encoding: 'ASCII-8BIT')
  HEADER_CLSID         = String.new("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", encoding: 'ASCII-8BIT')
  HEADER_MINOR_VERSION = String.new("\x3e\x00", encoding: 'ASCII-8BIT')
  MAXREGSID            = -6
  NOSTREAM             = -1
  STREAM               = 2

  # 2.6.1 Compound File Directory Entry
  #
  ENTRY_TYPES = ['unknown', 'storage', 'stream', 'lockbytes', 'property', 'root']

  # Initial seed filename
  #
  SEED_FILENAME = "\u0001Sh33tJ5"

  # Used internally for parser.
  #
  class SectorList < Array
    attr_accessor :fat_addrs
    attr_accessor :ssz
  end

  # =========================================================================
  # PUBLIC CLASS INTERFACE
  # =========================================================================

  # Returns +true+ if the executing computer is little-endian natively,
  # else +false+.
  #
  def self.host_is_little_endian?
    [42].pack('l').bytes[0] == 42
  end

  # Treat an input ASCII-8BIT encoded string as 4 bytes and from this parse and
  # return an unsigned 32-bit little-endian integer.
  #
  # +input+:: ASCII-8BIT encoded string including 4 byte sequence
  # +index+:: Index into +input+ to start reading bytes (default 0)
  #
  def self.get_uint32le(input, index = 0)
    data = input.slice(index, 4)
    data = data.reverse() unless self.host_is_little_endian?

    data.unpack('L').first
  end

  # Treat an input ASCII-8BIT encoded string as 4 bytes and from this parse and
  # return a signed 32-bit little-endian integer.
  #
  # +input+:: ASCII-8BIT encoded string including 4 byte sequence
  # +index+:: Index into +input+ to start reading bytes (default 0)
  #
  def self.get_int32le(input, index = 0)
    data = input.slice(index, 4)
    data = data.reverse() unless self.host_is_little_endian?

    data.unpack('l').first
  end

  # Parse a ctime/mtime 8-byte sequence (4 16-bit little endian pairs) into a
  # returned Ruby Time object, or +nil+ if the values are all zero.
  #
  # +data+:: ASCII-8BIT encoded string, 8 bytes long.
  #
  def self.get_time(data)
    high = self.get_uint32le(data, 4)
    low  = self.get_uint32le(data, 0)

    return nil if high.zero? && low.zero?

    high = (high / 1e7) * 2.pow(32)
    low  = (low  / 1e7)

    return Time.at(high + low - 11644473600).utc
  end

  # =========================================================================
  # PUBLIC INSTANCE INTERFACE
  # =========================================================================

  attr_accessor :full_paths, :file_index

  def initialize
    self.reinit()
  end

  # Add a file entry. Supports only root filenames only. File must not be
  # added already.
  #
  # +name+::    Filename, e.g. "Foo", in your preferred string encoding
  # +content+:: Mandatory ASCII-8BIT encoded string containing file data
  #
  def add(name, content)
    self.reinit()

    fpath = self.full_paths[0]

    if name.slice(0, fpath.size) == fpath
      fpath = name
    else
      fpath += '/' unless fpath.end_with?('/')
      fpath  = (fpath + name).gsub('//', '/')
    end

    file = OpenStruct.new({name: filename(name), type: 2, content: content, size: content.bytesize})

    self.file_index << file
    self.full_paths << fpath

    rebuild(force_gc: true)

    return file
  end

  # Compile and return the CFB file data.
  #
  def write

    # Commented out for now, because we prefer parity with the JS code for
    # test verification purposes. The overhead seems minimal.
    #
    # # Get rid of the seed file if it's still present and we seem to have
    # # more file entries than the root directory and seed entry.
    # #
    # seed_leaf  = "/#{SEED_FILENAME}"
    # seed_index = self.full_paths.find_index do | path |
    #   path.end_with?(seed_leaf)
    # end
    #
    # unless seed_index.nil? || self.file_index.size < 3
    #   self.file_index.delete_at(seed_index)
    #   self.full_paths.delete_at(seed_index)
    # end
    #
    # self.rebuild(force_gc: true)
    self.rebuild(force_gc: false)

    mini_size = 0
    fat_size  = 0

    0.upto(self.file_index.size - 1) do | i |
      flen = self.file_index[i]&.content&.bytesize
      next if flen.nil? || flen.zero?

      if flen < 0x1000
        mini_size += (flen + 0x3F) >> 6
      else
        fat_size  += (flen + 0x01FF) >> 9
      end
    end

    dir_cnt   = (self.full_paths.size + 3) >> 2
    mini_cnt  = (mini_size + 7) >> 3
    mfat_cnt  = (mini_size + 0x7F) >> 7
    fat_base  = mini_cnt + fat_size + dir_cnt + mfat_cnt
    fat_cnt   = (fat_base + 0x7F) >> 7
    difat_cnt = fat_cnt <= 109 ? 0 : ((fat_cnt - 109).to_f / 0x7F).ceil()

    while (((fat_base + fat_cnt + difat_cnt + 0x7F) >> 7) > fat_cnt)
      fat_cnt += 1
      difat_cnt = fat_cnt <= 109 ? 0 : ((fat_cnt - 109).to_f / 0x7F).ceil()
    end

    el = [1, difat_cnt, fat_cnt, mfat_cnt, dir_cnt, fat_size, mini_size, 0]

    self.file_index[0].size  = mini_size << 6
    self.file_index[0].start = el[0] + el[1] + el[2] + el[3] + el[4] + el[5]

    el[7] = el[0] + el[1] + el[2] + el[3] + el[4] + el[5] + ((el[6] + 7) >> 3)

    o = String.new(encoding: 'ASCII-8BIT')

    o << HEADER_SIGNATURE
    o << NUL * 2 * 8
    o << write_shift(2, 0x003E)
    o << write_shift(2, 0x0003)
    o << write_shift(2, 0xFFFE)
    o << write_shift(2, 0x0009)
    o << write_shift(2, 0x0006)
    o << NUL * 2 * 3

    o << write_shift( 4, 0)
    o << write_shift( 4, el[2])
    o << write_shift( 4, el[0] + el[1] + el[2] + el[3] - 1)
    o << write_shift( 4, 0)
    o << write_shift( 4, 1<<12)
    o << write_shift( 4, (el[3].blank? || el[3].zero?) ? ENDOFCHAIN : el[0] + el[1] + el[2] - 1)
    o << write_shift( 4, el[3])
    o << write_shift(-4, (el[1].blank? || el[1].zero?) ? ENDOFCHAIN : el[0] - 1)
    o << write_shift( 4, el[1])

    i = 0
    t = 0

    while i < 109
      o << write_shift(-4, i < el[2] ? el[1] + i : -1)
      i += 1
    end

    unless el[1].blank? || el[1].zero?
      t = 0
      while t < el[1]
        while i < 236 + t * 127
          o << write_shift(-4, i < el[2] ? el[1] + i : -1)
          i += 1
        end

        o << write_shift(-4, t == el[1] - 1 ? ENDOFCHAIN : t + 1)
        t += 1
      end
    end

    chainit = Proc.new do | w |
      t += w

      while i < t - 1
        o << write_shift(-4, i + 1)
        i += 1
      end

      unless w.blank? || w.zero?
        i += 1
        o << write_shift(-4, ENDOFCHAIN)
      end
    end

    i = 0
    t = el[1]

    while i < t
      o << write_shift(-4, DIFSECT)
      i += 1
    end

    t += el[2]

    while i < t
      o << write_shift(-4, FATSECT)
      i += 1
    end

    chainit.call(el[3])
    chainit.call(el[4])

    j    = 0
    flen = 0
    file = self.file_index[0]

    while j < self.file_index.size
      file = self.file_index[j]
      j   += 1

      next if file.content.nil?

      flen = file.content.bytesize
      next if flen < 0x1000

      file.start = t
      chainit.call((flen + 0x01FF) >> 9)
    end

    chainit.call((el[6] + 7) >> 3)

    while o.size & 0x1FF != 0
      o << write_shift(-4, ENDOFCHAIN)
    end

    t = i = j = 0

    while j < self.file_index.size do
      file = self.file_index[j]
      j   += 1

      next if file.content.nil?

      flen = file.content.bytesize
      next if flen == 0 || flen >= 0x1000

      file.start = t
      chainit.call((flen + 0x3F) >> 6)
    end

    while o.size & 0x1FF != 0
      o << write_shift(-4, ENDOFCHAIN)
    end

    i = 0

    while i < (el[4] << 2) do
      nm = self.full_paths[i]

      if nm.blank?
        0.upto(16) { o << write_shift(4,  0) } # Remember, #upto is inclusive -> *17* words
        0.upto(2 ) { o << write_shift(4, -1) }
        0.upto(11) { o << write_shift(4,  0) }

        i += 1
        next # NOTE EARLY LOOP RESTART
      end

      file = self.file_index[i]

      if i.zero?
        file.start = file.size.blank? || file.size.zero? ? ENDOFCHAIN : file.start - 1;
      end

      u_nm = file.name
      u_nm = u_nm[0...32] if u_nm.size > 32

      flen = 2 * (u_nm.size + 1)

      o << write_shift(64, u_nm, 'utf16le')
      o << write_shift(2, flen)
      o << write_shift(1, file.type)
      o << write_shift(1, file.color)
      o << write_shift(-4, file.L)
      o << write_shift(-4, file.R)
      o << write_shift(-4, file.C)

      if file.clsid.blank?
        j = 0
        while j < 4
          o << write_shift(4, 0)
          j += 1
        end
      else
        o << file.clsid
      end

      o << write_shift(4, file.state.blank? || file.state.zero? ? 0 : file.state)
      o << write_shift(4, 0)
      o << write_shift(4, 0)
      o << write_shift(4, 0)
      o << write_shift(4, 0)
      o << write_shift(4, file.start)
      o << write_shift(4, file.size)
      o << write_shift(4, 0)

      i += 1
    end

    i = 1

    while i < self.file_index.size do
      file = self.file_index[i]

      if file.size.present? && file.size >= 0x1000
        aligned_size = (file.start + 1) << 9
        while (o.size < aligned_size) do; o << 0x00; end

        o << file.content
        while (o.size % 512 != 0) do; o << 0x00; end
      end

      i += 1
    end

    i = 1

    while i < self.file_index.size do
      file = self.file_index[i]

      if file.size.present? && file.size > 0 && file.size < 0x1000
        o << file.content
        while (o.size % 64 != 0) do; o << 0x00; end
      end

      i += 1
    end

    while (o.size < el[7] << 9) do; o << 0x00; end

    return o
  end # "def write"

  # Parses an input file into this object, allowing you to extract individual
  # files thereafter via #read.
  #
  # +file+:: Source I/O stream. Data is read from the current file pointer,
  #          which will therefore have advanced when the method returns.
  #
  def parse!(file)
    raise "CFB corrupt - file size < 512 bytes" if file.size < 512

    mver          = 3
    ssz           = 512
    nmfs          = 0 # number of mini FAT sectors
    difat_sec_cnt = 0
    dir_start     = 0
    minifat_start = 0
    difat_start   = 0
    fat_addrs     = [] # locations of FAT sectors

    # [MS-CFB] 2.2 Compound File Header
    # Check major version
    #
    major, minor = self.check_get_mver(file)

    if major == 3
      ssz = 512
    elsif major == 4
      ssz = 4096
    elsif major == 0 && minor == 0
      raise 'Zip contents are not supported'
    else
      raise "Major version: Only 3 or 4 is supported; #{mver} encountered"
    end

    self.check_shifts(file, major)

    # Number of Directory Sectors
    #
    dir_cnt = self.read_shift(file, 4, 'i')
    raise "Directory sectors: Expected 0, saw #{dir_cnt}" if major == 3 && dir_cnt != 0

    # Number of FAT Sectors
    #
    file.seek(file.pos + 4)

    # First Directory Sector Location
    #
    dir_start = self.read_shift(file, 4, 'i')

    # Transaction Signature
    #
    file.seek(file.pos + 4)

    # Mini Stream Cutoff Size
    #
    self.check_field(file, "\x00\x10\x00\x00", 'Mini stream cutoff size')

    # First Mini FAT Sector Location
    #
    minifat_start = self.read_shift(file, 4, 'i')

    # Number of Mini FAT Sectors
    #
    nmfs = self.read_shift(file, 4, 'i')

    # First DIFAT sector location
    #
    difat_start = self.read_shift(file, 4, 'i')

    # Number of DIFAT Sectors
    #
    difat_sec_cnt = self.read_shift(file, 4, 'i')

    # Grab FAT Sector Locations
    #
    q = -1
    j = 0

    while (j < 109) # 109 = (512 - file.pos) >> 2
      q = self.read_shift(file, 4, 'i')
      break if q < 0
      fat_addrs[j] = q
      j += 1
    end

    # Break the file up into sectors, skipping the file header of 'ssz' size.
    #
    sectors = []
    file.seek(ssz)

    while ! file.eof?
      sectors << file.read(ssz)
    end

    self.sleuth_fat(difat_start, difat_sec_cnt, sectors, ssz, fat_addrs)

    # Chains
    #
    sector_list = self.make_sector_list(sectors, dir_start, fat_addrs, ssz)
    sector_list[dir_start].name = '!Directory'

    if nmfs > 0 && minifat_start != ENDOFCHAIN
      sector_list[minifat_start].name = '!MiniFAT'
    end

    sector_list[fat_addrs[0]].name = '!FAT'
    sector_list.fat_addrs          = fat_addrs
    sector_list.ssz                = ssz

    # [MS-CFB] 2.6.1 Compound File Directory Entry
    #
    files = {}
    paths = []

    self.full_paths = []
    self.file_index = []
    self.read_directory(
      dir_start,
      sector_list,
      sectors,
      paths,
      nmfs,
      files,
      minifat_start
    )

    self.build_full_paths(paths)
  ensure
    file.close() unless file.nil?
  end # "def parse!"

  # =========================================================================
  # PRIVATE INSTANCE METHODS
  # =========================================================================
  #
  private

    # Initialise or reinitialise the internal file data. After being called
    # for the first time, calling here is really only useful to make sure
    # that internal file path and index arrays look consistent.
    #
    def reinit
      self.full_paths ||= []
      self.file_index ||= []

      if self.full_paths.size != self.file_index.size
        raise 'Inconsistent CFB structure'
      end

      if self.full_paths.size == 0
        root = 'Root Entry'

        self.full_paths << root + '/'
        self.file_index << OpenStruct.new({name: root, type: 5})

        # Add starting seed file
        #
        nm = SEED_FILENAME
        p  = [55, 50, 54, 50].pack('C*')

        self.full_paths << self.full_paths[0] + nm
        self.file_index << OpenStruct.new({name: nm, type: 2, content: p, R: 69, L: 69, C: 69})
      end
    end

    # Strange function that's very much not the same as "File.dirname".
    #
    def dirname(p)
      if p.end_with?('/')
        chomped = p.chomp('/')
        return chomped.include?('/') ? self.dirname(chomped) : p # NOTE EARLY EXIT AND RECURSION
      end

      c = p.rindex('/')

      return c.nil? ? p : p.slice(0, c + 1)
    end

    # Strange function that's very much not the same as "File.basename".
    #
    def filename(p)
      if p.end_with?('/')
        return filename(p.chomp('/')) # NOTE EARLY EXIT AND RECURSION
      end

      c = p.rindex('/')

      return c.nil? ? p : p[(c + 1)..]
    end

    # Compare file-path-name with some FAT concepts thrown in (L vs R); related
    # to CFB section 2.6.4 (red-black trees).
    #
    def namecmp(l, r)
      el = l.split('/')
      ar = r.split('/')
      i  = 0
      z  = [el.size, ar.size].min

      while i < z do
        c = el[i].size - ar[i].size

        return c                     if c     != 0
        return el[i] < r[i] ? -1 : 1 if el[i] != ar[i]

        i += 1
      end

      return el.size - ar.size
    end

    # CFB internal knowledge would be required to understand this; seems to be
    # recalculating data structures that then theoretically would make life
    # easier during the file output stage.
    #
    def rebuild(force_gc: false)
      self.reinit()

      s  = false
      gc = force_gc

      unless gc == true
        (self.full_paths.size - 1).downto(0) do | i |
          file = self.file_index[i]

          case file.type
            when 0
              if s == true
                gc = true
              else
                self.file_index.pop()
                self.full_paths.pop()
              end

            when 1, 2, 5
              s    = true
              gc ||= (file.R * file.L * file.C rescue nil).nil?
              gc ||= file.R.try(:>, -1) && file.L.try(:>, -1) && file.R == file.L

            else
              gc = true
          end
        end
      end

      return unless gc == true

      now = Date.parse('1987-01-19')

      # Track which names exist

      track_full_paths = {}
      data             = []

      0.upto(self.full_paths.size - 1) do | i |
        track_full_paths[self.full_paths[i]] = true
        next if self.file_index[i].type == 0
        data.push([self.full_paths[i], self.file_index[i]])
      end

      0.upto(data.size - 1) do | i |
        dad = self.dirname(data[i][0])
        s   = track_full_paths[dad]

        while s.blank?
          while self.dirname(dad).present? && track_full_paths[self.dirname(dad)].blank?
            dir = self.dirname(dad)
          end

          data.push([
            dad,
            OpenStruct.new({
              name:    self.filname(dad).gsub('/', ''),
              type:    1,
              clsid:   HEADER_CLSID,
              ct:      now,
              mt:      now,
              content: null
            })
          ])

          # Add name to set
          #
          track_full_paths[dad] = true

          dad = self.dirname(data[i][0])
          s   = track_full_paths[dad]
        end
      end

      data.sort! { |x, y| self.namecmp(x[0], y[0]) }

      self.full_paths = []
      self.file_index = []

      0.upto(data.size - 1) do | i |
        self.full_paths << data[i][0]
        self.file_index << data[i][1]
      end

      0.upto(data.size - 1) do | i |
        nm  = self.full_paths[i]
        elt = self.file_index[i]

        elt.name  = self.filename(nm).gsub('/', '')
        elt.color = 1
        elt.L     = -1
        elt.R     = -1
        elt.C     = -1
        elt.size  = elt.content.nil? ? 0 : elt.content.bytesize
        elt.start = 0
        elt.clsid = elt.clsid || HEADER_CLSID

        if i == 0
          elt.C    = data.size > 1 ? 1 : -1
          elt.size = 0
          elt.type = 5

        elsif nm.end_with?('/')
          j = i + 1
          while j < data.size do
            break if self.dirname(self.full_paths[j]) == nm
            j += 1
          end

          elt.C = j >= data.size ? -1 : j

          j = i + 1
          while j < data.size do
            break if self.dirname(self.full_paths[j]) == self.dirname(nm)
            j += 1
          end

          elt.R = j >= data.size ? -1 : j
          elt.type = 1

        else
          elt.R = i + 1 if self.dirname(self.full_paths[i + 1] || '') == self.dirname(nm)
          elt.type = 2

        end
      end
    end

    # Returns a chunk of data representing a converted write of the input in
    # the +value+ parameter.
    #
    # The JS code from which this was ported has a very, VERY strange method
    # signature...
    #
    # +size+::   Either a number of bytes to write or a format specifier (see
    #            below).
    #
    # +value+::  A value to write; its type is interpreted through both the
    #            +size+ and +format+ parameters.
    #
    # +format+:: Either 'hex' or 'utf16le' in which case the value is treated
    #            as a hex string (e.g. "deadbeef", high nibble first) or
    #            character data in arbitrary Ruby string encoding; written to
    #            the output as parsed bytes from the hex data, or little
    #            endian UTF-16 byte pairs, respectively. If the input value
    #            is longer than +size+ *IN BYTES* then it is truncated, else
    #            if need be, padded with zeros - again *IN BYTES*, so the
    #            maximum length in characters of a "utf16le" string is half
    #            the amount in +size+.
    #
    #            If +format+ is something else or omitted, "size" becomes an
    #            indication of format (!). The value is treated as an 8-bit
    #            byte (+size+ is 1) and masked as such, 16-bit unsigned
    #            little-endian value (2), or uint32 (4) - or a signed int32
    #            (+size+ is -4 - yes, that's minus 4) - written out as four
    #            bytes, little-endian.
    #
    def write_shift(size, value, format = nil)
      output_buffer = nil

      case format
        when 'hex'
          bytes = [value].pack('H*').ljust(size, NUL)
          bytes = bytes[0...size]

          output_buffer = bytes

        when 'utf16le'
          chars = value.ljust(size / 2, NUL)
          chars = chars[0...(size / 2)]

          output_buffer = chars.encode('UTF-16LE').force_encoding('ASCII-8BIT')

        else
          case size
            when 1
              output_buffer = [value].pack('C') # Unsigned 8-bit, bitwise truncated
            when 2
              output_buffer = [value].pack('v') # Unsigned 16-bit little-endian, bitwise truncated
            when 4
              output_buffer = [value].pack('V') # Unsigned 32-bit little-endian, bitwise truncated
            when -4
              int32_4_bytes = [value].pack('l')
              int32_4_bytes = int32_4_bytes.reverse() unless self.class.host_is_little_endian?
              output_buffer = int32_4_bytes
          end
      end

      return output_buffer
    end

    # A method that's a companion to #write_shift and equally strange!
    #
    # Read from file for 'size' bytes if size is 1, 2 or 4, parsing the bytes
    # as an 8-bit unsigned, 16-bit unsigned or 32-bit integer where the value
    # of 't' indicates if the 32-bit integer is signed ('t' is string 'i') or
    # unsigned ('t' is anything else); or if size is 16, just return a string
    # of 16 bytes read as-is.
    #
    # This implementation is slightly cleaner and more appropriate than the
    # one in the original source, by omitting unused conversions.
    #
    # +file+:: Source I/O stream. Data is read from the current file pointer,
    #          which will therefore have advanced when the method returns.
    #
    # +size+:: 1, 2, 4 to read 1, 2 or 4 bytes returned as a parsed 8, 16 or
    #          32-bit little-endian integer respectively, or pass 16 to read
    #          16 bytes of raw data returned as an ASCII-8BIT encoded string.
    #
    # +type+:: If +size+ is 4, pass 'i' to read as a signed 32-bit integer,
    #          else (omitted, or not 'i') value is read as unsigned.
    #
    def read_shift(file, size, t = nil)
      return case size
        when 1 # Unsigned 8-bit
          file.read(1).bytes.first

        when 2 # Unsigned 16-bit little-endian
          file.read(2).unpack('v').first

        when 4 # 32-bit little-endian signed or unsigned
          data = file.read(4)

          if t == 'i' # Signed 32-bit little-endian
            self.class.get_int32le(data)
          else # Unsigned 32-bit little-endian
            self.class.get_uint32le(data)
          end

        when 16
          file.read(16)
      end
    end

    # Read from the file, expecting to see a particular value; if not, throw
    # an exception.
    #
    # +file+::       Source I/O stream. Data is read from the current file
    #                pointer, which will therefore have advanced when the
    #                method returns.
    #
    # +expected+::   The expected value, as a String that'll be forced to
    #                ASCII-8BIT encoding, if not that way already.
    #
    # +field_name+:: The field name to include in the raised exception, just
    #                for human diagnostic purposes.
    #
    def check_field(file, expected, field_name)
      expected = expected.dup.force_encoding('ASCII-8BIT')
      data     = file.read(expected.bytesize)

      if data != expected
        raise "#{field_name}: Expected #{expected.inspect}, but got #{data.inspect}"
      end
    end

    # Return a tuple array of major, minor file version, with 0, 0 for ZIP
    # files, else read from the CFB file, checking header in passing. File
    # pointer is assumed to be at zero on entry.
    #
    # +file+:: Source I/O stream. Data is read from the current file pointer,
    #          which will therefore have advanced when the method returns.
    #
    def check_get_mver(file)
      return [0, 0] if file.read(1) == 0x50 && file.read(1) == 0x4b

      file.rewind()
      check_field(file, HEADER_SIGNATURE, 'Header signature')

      file.seek(file.pos + 16) # Skip all-NUL CLSID, 16 bytes

      # Minor version
      minor = self.read_shift(file, 2)
      major = self.read_shift(file, 2)

      return [major, minor]
    end

    # Check sector shifts in the file header.
    #
    # +file+::  Source I/O stream. Data is read from the current file pointer,
    #           which will therefore have advanced when the method returns.
    #
    # +major+:: Major version number - must be 3 or 4.
    #
    def check_shifts(file, major)

      # Skip byte order marker (always indicates little-endian)
      #
      file.seek(file.pos + 2)

      shift = self.read_shift(file, 2)

      case shift
        when 0x09
          raise "Sector shift: Expected 9, saw #{shift}" if major != 3
        when 0x0c
          raise "Sector shift: Expected 12, saw #{shift}" if major != 4
        else
          raise "Sector shift: Unsupported value #{shift}"
      end

      # Mini Sector Shift
      #
      self.check_field(file, "\x06\x00", 'Mini sector shift')

      # Reserved
      #
      self.check_field(file, "\x00\x00\x00\x00\x00\x00", 'Reserved')
    end

    # Chase down the rest of the DIFAT chain to build a comprehensive list
    # DIFAT chains by storing the next sector number as the last 32 bits.
    #
    # +idx+::       Sector index; usually, start DIFAT sector initially
    # +cnt+::       DIFAT sector count expected
    # +sectors+::   Array of sectors
    # +ssz+::       Size of a sector
    # +fat_addrs+:: Array MODIFIED IN PLACE with sector addresses added
    #
    def sleuth_fat(idx, cnt, sectors, ssz, fat_addrs)
      q = ENDOFCHAIN

      if idx == ENDOFCHAIN
        raise 'DIFAT chain shorter than expected' if cnt != 0
      elsif idx != FREESECT
        sector = sectors[idx]
        m      = (ssz >> 2) - 1
        i      = 0

        return if sector.nil?

        while i < m
          q = self.class.get_int32le(sector, i * 4)
          break if q == ENDOFCHAIN

          fat_addrs << q
          i += 1
        end

        if cnt >= 1
          self.sleuth_fat(
            self.class.get_int32le(sector, ssz - 4),
            cnt - 1,
            sectors,
            ssz,
            fat_addrs
          )
        end
      end
    end

    # Follow the linked list of sectors for a given starting point.
    #
    # Parameters need to be guessed from caller use cases.
    #
    def get_sector_list(sectors, start, fat_addrs, ssz, chkd)
      chkd    ||= []
      buf       = []
      buf_chain = []
      modulus   = ssz - 1
      j         = start
      jj        = 0

      while j >= 0
        chkd[j] = true
        buf[buf.length] = j
        buf_chain.push(sectors[j])

        addr = fat_addrs[((j * 4).to_f / ssz).floor()]
        jj   = ((j * 4) & modulus)

        raise "FAT boundary crossed: #{j} 4 #{ssz}" if ssz < 4 + jj
        break if sectors[addr].nil?

        j = self.class.get_int32le(sectors[addr], jj)
      end

      return OpenStruct.new(nodes: buf, data: buf_chain.join)
    end

    # Chase down the sector linked lists.
    #
    # Parameters need to be guessed from caller use cases.
    #
    def make_sector_list(sectors, dir_start, fat_addrs, ssz)
      sl          = sectors.length
      sector_list = SectorList.new
      chkd        = []
      buf         = []
      buf_chain   = []

      modulus     = ssz - 1
      i           = 0
      j           = 0
      k           = 0
      jj          = 0

      0.upto(sl - 1) do | i |
        buf = []
        k   = i + dir_start
        k  -= sl if k >= sl

        next if chkd[k]

        buf_chain = []
        seen      = []
        j         = k

        while j >= 0
          seen[j] = true
          chkd[j] = true

          buf[buf.size] = j;
          buf_chain << sectors[j]

          addr = fat_addrs[((j * 4).to_f / ssz).floor()]
          jj   = (j * 4) & modulus

          raise "FAT boundary crossed: #{j} 4 #{ssz}" if ssz < 4 + jj
          break if sectors[addr].nil?

          j = self.class.get_int32le(sectors[addr], jj)
          break if seen[j]
        end

        sector_list[k] = OpenStruct.new(nodes: buf, data: buf_chain.join())
      end

      return sector_list
    end

    # [MS-CFB] 2.6.1 Compound File Directory Entry.
    #
    # Parameters need to be guessed from caller use cases.
    #
    def read_directory(dir_start, sector_list, sectors, paths, nmfs, files, mini)
      minifat_store = 0
      pl            = paths.any? ? 2 : 0
      sector        = sector_list[dir_start].data
      i             = 0
      namelen       = 0
      name          = nil

      while i < sector.size
        blob = StringIO.new(sector.slice(i, 128))

        blob.seek(64)
        namelen = self.read_shift(blob, 2)

        blob.seek(0)
        name = blob.read(namelen - pl).force_encoding('UTF-16LE')
        nul_terminator = String.new("\x00\x00", encoding: 'UTF-16LE')
        name.chomp!(nul_terminator)
        name.encode!('UTF-8')

        paths << name

        blob.seek(66)
        o = OpenStruct.new({
          name:  name,
          type:  self.read_shift(blob, 1),
          color: self.read_shift(blob, 1),
          L:     self.read_shift(blob, 4, 'i'),
          R:     self.read_shift(blob, 4, 'i'),
          C:     self.read_shift(blob, 4, 'i'),
          clsid: self.read_shift(blob, 16),
          state: self.read_shift(blob, 4, 'i'),
          start: 0,
          size:  0
        })

        o.ct    = self.class.get_time(blob.read(8))
        o.mt    = self.class.get_time(blob.read(8))
        o.start = self.read_shift(blob, 4, 'i')
        o.size  = self.read_shift(blob, 4, 'i')

        if o.size < 0 && o.start < 0
          o.size  = o.type = 0
          o.start = ENDOFCHAIN
          o.name  = ''
        end

        if o.type === 5 # Root
          minifat_store = o.start

          if nmfs > 0 && minifat_store != ENDOFCHAIN
            sector_list[minifat_store].name = '!StreamData'
          end
        elsif o.size >= 4096 # MSCSZ
          o.storage = 'fat'
          if sector_list[o.start].nil?
            sector_list[o.start] = self.get_sector_list(sectors, o.start, sector_list.fat_addrs, sector_list.ssz)
          end
          sector_list[o.start].name = o.name
          o.content = sector_list[o.start].data.slice(0, o.size)
        else
          o.storage = 'minifat';

          if o.size < 0
            o.size = 0
          elsif minifat_store != ENDOFCHAIN && o.start != ENDOFCHAIN && ! sector_list[minifat_store].nil?
            o.content = self.get_mfat_entry(o, sector_list[minifat_store].data, sector_list[mini]&.data)
          end
        end

        files[name] = o;
        self.file_index << o

        i += 128
      end
    end

    # [MS-CFB] 2.6.4 Red-Black Tree.
    #
    # +paths+:: Array of incomplete paths (often just leafnames) where indices
    #           in the array correspond to "self.file_index" entries; contents
    #           in "self.full_paths" will be overwritten if present.
    #
    def build_full_paths(paths)
      i   = 0
      j   = 0
      el  = ar = ce = 0
      pl  = paths.length
      dad = []
      q   = []

      while i < pl
        dad[i] = q[i] = i
        self.full_paths[i] = paths[i]

        i += 1
      end

      while j < q.length
        i  = q[j]
        el = self.file_index[i].L
        ar = self.file_index[i].R
        ce = self.file_index[i].C

        if dad[i] == i
          dad[i] = dad[el] if el != NOSTREAM && dad[el] != el
          dad[i] = dad[ar] if ar != NOSTREAM && dad[ar] != ar
        end

        dad[ce] = i if ce != NOSTREAM

        if el != NOSTREAM && i != dad[i]
          dad[el] = dad[i]
          q << el if q.rindex(el) < j
        end

        if ar != NOSTREAM && i != dad[i]
          dad[ar] = dad[i]
          q << ar if q.rindex(ar) < j
        end

        j += 1
      end

      1.upto(pl - 1) do | i |
        if dad[i] == i
          if ar != NOSTREAM && dad[ar] != ar
            dad[i] = dad[ar]
          elsif el != NOSTREAM && dad[el] != el
            dad[i] = dad[el]
          end
        end
      end

      1.upto(pl - 1) do | i |
        next if self.file_index[i].type == 0 # (unknown)

        j = i;

        if j != dad[j]
          loop do
            j = dad[j]
            self.full_paths[i] = self.full_paths[j] + '/' + self.full_paths[i]

            break unless j != 0 && NOSTREAM != dad[j] && j != dad[j]
          end
        end

        dad[i] = -1
      end

      self.full_paths[0] << '/'

      1.upto(pl - 1) do | i |
        if self.file_index[i].type != STREAM
          self.full_paths[i] << '/'
        end
      end
    end

    # Read entry contents. Undocumented in JS code; looks like:
    #
    # +entry+::   The internal file structure being compiled; updated on exit
    # +payload+:: MiniFAT sector data (file contents within)
    # +mini+::    MiniFAT indices (of file contents in sector data)
    #
    # Returns the extracted data as an ASCII-8BIT encoded string.
    #
    def get_mfat_entry(entry, payload, mini)
      start = entry.start
      size  = entry.size
      o     = String.new(encoding: 'ASCII-8BIT')
      idx   = start;

      while mini.present? && size > 0 && idx >= 0 do
        o << payload.slice(idx * MSSZ, MSSZ)
        size -= MSSZ
        idx = self.class.get_int32le(mini, idx * 4)
      end

      return '' if o.bytesize == 0
      return o.slice(0, entry.size)
    end

end # "class SimpleCfb"
