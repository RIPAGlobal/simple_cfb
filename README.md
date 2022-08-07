# SimpleCFB
## Overview

SimpleCFB implements ways to read and write CFB files in pure Ruby. It is a port of parts of:

* https://github.com/SheetJS/js-cfb

CFB (Container File Binary) is a Microsoft-originated container format based on FAT:

* https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/

CFB files are used to wrap OOXML data when an Excel spreadsheet is encrypted with a password. Support for encrypted OOXML files in Ruby was the primary reason for creating the Simple CFB gem. If you're interested in that, then https://github.com/RIPAGlobal/ooxml_encryption may be of interest.



## Installation

Install the gem and add to the application's `Gemfile` by executing:

    $ bundle add simple_cfb

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install simple_cfb



## Usage
### Writing a file

Create a new CFB object.

```ruby
require 'simple_cfb'

cfb = SimpleCfb.new
```

Add files by filename. Filenames can be given in any valid string encoding, but are **limited to 31 characters** maximum and can only use characters which can be **transcoded into UTF-16**. File data is given an `ASCII-8BIT` encoded string which is not interpreted or modified in any way. Use of folders (via filenames including a `/` separator) are theoretically supported but not tested and, therefore, discouraged.

```ruby
cfb.add('SomeFilename', file_data)
cfb.add('AnotherFile',  more_file_Data)
```

"Write" the CFB object contents into a single compiled object, returned as an `ASCII-8BIT` encoded string. You can then write this to a file using normal Ruby methods. Note that binary writing must be selected (`wb` mode) to avoid corruption.

```ruby
output = cfb.write()

File.open('/path/to/output.cfb', 'wb') do | file |
  file.write(output)
end
```

### Reading a file

Create a new CFB object.

```ruby
cfb = SimpleCfb.new
```

"Parse" an input file into the CFB data, updating the object. Note that binary reading (`rb` mode) must be used. If you already have something
like an ASCII-8BIT encoded string and want to parse that instead, you can wrap it in a StringIO - e.g. `cfb.parse!(StringIO.new(str))`.

```ruby
File.open('/path/to/input.cfb', 'rb') do | file |
  cfb.parse!(file)
end
```

The CFB object's files can now be examined through properties `file_index` and `full_paths` - two arrays that give information on the files in the container, read as pairs with the same index in each array referring to the same file entry. Index 0 always contains the root object and index 1 contains an entry with a strange filename derived from `SheetJS`; these can be safely ignored, with the `SheetJS` entry in particular included only for intentional binary-level parity with the original JavaScript source code from which SimpleCFB was created.

The file index entries are of most interest; you can search the array entries by `name` property values and obtain file data from the `content` properties as `ASCII-8BIT` encoded strings. For example, given this:

```ruby
require 'simple_cfb'

cfb_writer = SimpleCfb.new
cfb_writer.add('hello.txt', '1234')

cfb_data = cfb_writer.write()
#=> "\xD0\xCF\x11..."

cfb_reader = SimpleCfb.new
cfb_reader.parse!(StringIO.new(cfb_data))

cfb_reader.full_paths
# => ["Root Entry/", "Root Entry/\u0001Sh33tJ5", "Root Entry/hello.txt", "/"]

cfb_reader.file_index
# => [
#  <OpenStruct name="Root Entry/", ...>,
#  <OpenStruct name="\u0001Sh33tJ5", ...>,
#  <OpenStruct name="hello.txt", ..., content="1234">,
#  <OpenStruct name="/" ...]
```

...then you could extract data for a specific file via `Array#find` using `name`. Note that the CFB `UTF-16LE`-encoded filenames are re-encoded to UTF-8 for convenience, so you don't need to worry about that when comparing names:

```
file_entry = cfb_reader.file_index.find { |f| f.name == 'hello.txt' }
file_data  = file_entry.content
# => "1234"
```



## Resource overhead

Due to the nature of the original file format, which has various tables written at the start of the file that can only be built once the file contents are known, CFB files have to be compiled or parsed in RAM. Streamed output or input is not possible. Attempting to create or read large CFB files is therefore not recommended - there could be very large RAM requirements arising.



## Other notes

Code quality is by Ruby standards - uhh - exciting... The original source was certainly an interesting thing to try and port. Most of the time it's a close copy of the original with several sections that I didn't even understand and simply transcribed to Ruby.

Verification involved reading and writing files output by the original JavaScript source code, then comparing binary results with the Ruby port. Bugs are likely, in both the original code given its opacity and in the Ruby port given the likelihood of transcription errors. It suffices for the encrypted OOXML original use case; the code coverage report from running tests shows some significant gaps.



## Development

Use `bundle exec rspec` to run tests. Run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. If you have sufficient RubyGems access to release a new version, update the version number and date in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

Locally generated RDoc HTML seems to contain a more comprehensive and inter-linked set of pages than those available from `rubydoc.info`. You can (re)generate the internal [`rdoc` documentation](https://ruby-doc.org/stdlib-2.4.1/libdoc/rdoc/rdoc/RDoc/Markup.html#label-Supported+Formats) with:

```shell
bundle exec rake rerdoc
```

...yes, that's `rerdoc` - Re-R-Doc - then open `docs/rdoc/index.html`.



## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/RIPAGlobal/simple_cfb.
