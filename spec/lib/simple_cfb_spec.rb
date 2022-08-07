require 'spec_helper'

RSpec.describe SimpleCfb do
  before :each do
    @cfb = described_class.new
  end

  context 'private method verification' do
    it "#dirname matches its JavaScript counterpart's behaviour" do
      data = {
        ''                => '',
        '/'               => '/',
        '/foo'            => '/',
        '/foo/'           => '/',
        '/foo/bar'        => '/foo/',
        '/foo/bar/'       => '/foo/',
        '/foo/bar/baz'    => '/foo/bar/',
        '/foo/bar/baz/'   => '/foo/bar/',
        '/foo/bar/baz///' => '/foo/bar/',
      }

      data.each do | input, output |
        expect(@cfb.send(:dirname, input)).to eql(output)
      end
    end

    it "#filename matches its JavaScript counterpart's behaviour" do
      data = {
        ''                => '',
        '/'               => '',
        '/foo'            => 'foo',
        '/foo/'           => 'foo',
        '/foo/bar'        => 'bar',
        '/foo/bar/'       => 'bar',
        '/foo/bar/baz'    => 'baz',
        '/foo/bar/baz/'   => 'baz',
        '/foo/bar/baz///' => 'baz',
      }

      data.each do | input, output |
        expect(@cfb.send(:filename, input)).to eql(output)
      end
    end

    it "#namecmp matches its JavaScript counterpart's behaviour" do
      data = {
        ['foo',         'bar'        ] => 1,
        ['bar',         'foo'        ] => -1,
        ['foo/bar',     'bar'        ] => 1,
        ['foo',         'foo'        ] => 0,
        ['foo/bar',     'foo'        ] => 1,
        ['foo',         'foo/bar'    ] => -1,
        ['foo/bar',     'foo/bar'    ] => 0,
        ['foo/bar/baz', 'foo/bar'    ] => 1,
        ['foo/bar',     'foo/bar/baz'] => -1,
        ['foo/bar/baz', 'foo/bar/baz'] => 0,
        ['foo/bar/zzz', 'foo/bar/baz'] => 1,
        ['foo/bar/baz', 'foo/bar/zzz'] => -1,
      }

      data.each do | input, output |
        expect(@cfb.send(:namecmp, *input)).to eql(output)
      end
    end

    it "#write_shift matches its JavaScript counterpart's behaviour" do
      data = {
        [ 4, '4080c1ff0120', 'hex'    ] => [64, 128, 193, 255        ], # Parse string as hex digits, high nibble first, max bytes in first parameter
        [ 8, 'abc',          'utf16le'] => [97, 0, 98, 0, 99, 0, 0, 0], # Output string as UTF-16 little-endian, padding to number of bytes given
        [ 1, 41                       ] => [41                       ], # Char...
        [ 1, 250                      ] => [250                      ], # ...unsigned
        [ 2, 0x1234                   ] => [52,  18                  ], # 16-bit little-endian...
        [ 2, 0xFFE4                   ] => [228, 255                 ], # ...unsigned
        [ 4, 0x12345678               ] => [120, 86,  52,  18        ], # 32-bit little-endian...
        [ 4, 0xFFFFFFE4               ] => [228, 255, 255, 255       ], # ...unsigned, or...
        [-4, -31                      ] => [225, 255, 255, 255       ], # ...signed
      }

      data.each do | input, output |
        expect(@cfb.send(:write_shift, *input).bytes).to eql(output)
      end
    end

    it "#read_shift matches its JavaScript counterpart's behaviour, where applicable" do
      data = {
        [[250               ], 1, nil] => 250,        # 8-bit unsigned
        [[228, 255          ], 2, nil] => 0xFFE4,     # 16-bit little-endian unsigned
        [[228, 255, 255, 255], 4, nil] => 0xFFFFFFE4, # 32-bit little-endian unsigned
        [[225, 255, 255, 255], 4, 'i'] => -31         # 32-bit little-endian signed
      }

      data.each do | input, output |
        str = input.shift.pack('C*')
        expect(@cfb.send(:read_shift, StringIO.new(str), *input)).to eql(output)
      end
    end

    it '#read_shift reads exactly 16 bytes if so asked' do
      str = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20].pack('C*')
      hex = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F"

      expect(@cfb.send(:read_shift, StringIO.new(str), 16)).to eql(String.new(hex, encoding: 'ASCII-8BIT'))
    end
  end # "context 'private method verification' do"

  context 'overall data output' do
    it 'writes small file data that matches its JavaScript counterpart' do
      input = File.open(File.join(__dir__, '..', 'fixtures', 'node_small_file.bin'), 'rb') { | file | file.read() }

      @cfb.add('hello.txt', '1234')
      output = @cfb.write()

      expect(input).to eql(output)
    end

    it 'writes large file data that matches its JavaScript counterpart' do
      input = File.open(File.join(__dir__, '..', 'fixtures', 'node_large_file.bin'), 'rb') { | file | file.read() }

      @cfb.add('goodbye.txt', '!' * 7491)
      output = @cfb.write()

      expect(input).to eql(output)
    end
  end # "context 'overall data output' do"

  context 'overall data input' do
    it 'reads small files written by its JavaScript counterpart' do
      File.open(File.join(__dir__, '..', 'fixtures', 'node_small_file.bin'), 'rb') do | file |
        @cfb.parse!(file)
      end

      # 0: Root entry
      # 1: "\u0001Sh33tJ5"
      # 2: File of interest
      #
      # The UTF-8 encoding is redundant since the input hard-coded string
      # *ought* to be UTF-8 by default, but it's there explicitly really
      # just to illustrate the in-passing proof that the parsed names have
      # been re-encoded from UTF-16LE to UTF-8.
      #
      expect(@cfb.file_index[2].name).to eql('hello.txt'.encode('UTF-8'))
      expect(@cfb.file_index[2].content).to eql('1234')
    end

    it 'reads large files written by its JavaScript counterpart' do
      node_data = File.open(File.join(__dir__, '..', 'fixtures', 'node_large_file.bin'), 'rb') do | file |
        @cfb.parse!(file)
      end

      # 0: Root entry
      # 1: "\u0001Sh33tJ5"
      # 2: File of interest
      #
      expect(@cfb.file_index[2].name).to eql('goodbye.txt'.encode('UTF-8'))
      expect(@cfb.file_index[2].content).to eql('!' * 7491)
    end
  end # "context 'overall data input' do"
end
