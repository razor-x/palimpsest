require 'spec_helper'

describe Palimpsest::Assets do
  let(:utils) { Palimpsest::Utils }
  let(:config) do
    YAML.load <<-EOF
      :options:
        :js_compressor: :uglifier
        :not_a_good_setting: :some_value
      :paths:
        - assets/javascripts
        - other/javascripts
    EOF
  end

  subject(:assets) { Palimpsest::Assets.new }

  describe ".new" do
    it "sets default options" do
      expect(assets.options).to eq Palimpsest::Assets::DEFAULT_OPTIONS
    end

    it "merges default options" do
      assets = Palimpsest::Assets.new options: { src_pre: '{{' }
      expect(assets.options).to eq Palimpsest::Assets::DEFAULT_OPTIONS.merge(src_pre: '{{')
    end
  end

  describe "#options" do
    it "merges with default options" do
      assets.options[:src_pre] = '{{'
      expect(assets.options).to eq Palimpsest::Assets::DEFAULT_OPTIONS.merge(src_pre: '{{')
    end

    it "can be called twice and merge options" do
      assets.options[:src_pre] = '{{'
      assets.options[:src_post] = '}}'
      expect(assets.options).to eq Palimpsest::Assets::DEFAULT_OPTIONS.merge(src_pre: '{{', src_post: '}}')
    end
  end

  describe "#sprockets" do
    it "returns a new sprockets environment" do
      expect(assets.sprockets).to be_a Sprockets::Environment
    end
  end

  describe "#load_options" do
    subject(:assets) { Palimpsest::Assets.new options: config[:options] }

    it "returns itself" do
      expect(assets.load_options).to be assets
    end

    it "sets the options for sprockets" do
      expect(assets.sprockets).to receive(:js_compressor=).with(:uglifier)
      assets.load_options
    end

    it "does not load an unset setting" do
      expect(assets.sprockets).to_not receive(:css_compressor)
      assets.load_options
    end

    it "does not load an invalid setting" do
      expect(assets.sprockets).to_not receive(:not_a_good_setting)
      assets.load_options
    end

    context "no options" do
      it "does not fail when options not set" do
        expect { assets.load_options }.to_not raise_error
      end
    end
  end

  describe "#load_paths" do
    subject(:assets) { Palimpsest::Assets.new paths: config[:paths] }

    it "returns itself" do
      expect(assets.load_paths).to be assets
    end

    context "when directory set" do
      it "loads the paths for the given set into the sprockets environment" do
        assets.directory = '/tmp/root_dir'
        expect(assets.sprockets).to receive(:append_path).with('/tmp/root_dir/assets/javascripts')
        expect(assets.sprockets).to receive(:append_path).with('/tmp/root_dir/other/javascripts')
        assets.load_paths
      end
    end

    context "when no directory set" do
      it "loads the paths for the given set into the sprockets environment" do
        expect(assets.sprockets).to receive(:append_path).with('assets/javascripts')
        expect(assets.sprockets).to receive(:append_path).with('other/javascripts')
        assets.load_paths
      end
    end

    context "when no paths set" do
      it "does not fail" do
        assets.paths = {}
        expect { assets.load_paths }.to_not raise_error
      end
    end
  end

  describe "#assets" do
    subject(:assets) { Palimpsest::Assets.new paths: config[:paths] }

    it "loads options" do
      expect(assets).to receive :load_options
      assets.assets
    end

    it "loads paths" do
      expect(assets).to receive :load_paths
      assets.assets
    end

    it "does not load options and paths twice" do
      expect(assets).to receive(:load_options).once
      expect(assets).to receive(:load_paths).once
      assets.assets
      assets.assets
    end

    it "returns compiled assets" do
      expect(assets.assets).to equal assets.sprockets
    end
  end

  describe "#write" do
    let(:asset) { double Sprockets::Asset }

    before :each do
      assets.options hash: false
      allow(assets.assets).to receive(:[]).with('lib/app').and_return(asset)
      allow(asset).to receive(:logical_path).and_return('lib/app.js')
    end

    context "asset not found" do
      it "returns nil" do
        allow(assets.assets).to receive(:[]).with('not_here').and_return(nil)
        expect(assets.write 'not_here').to be nil
      end
    end

    context "output is set with no directory set" do
      it "writes to relative path and returns the relative path" do
        assets.options output: 'compiled'
        expect(asset).to receive(:write_to).with("compiled/lib/app.js")
        expect(assets.write 'lib/app').to eq "compiled/lib/app.js"
      end
    end

    context "output is set with directory set" do
      it "writes to relative path under directory and returns the relative path" do
        assets.options output: 'compiled'
        assets.directory = '/tmp/dir'
        expect(asset).to receive(:write_to).with("/tmp/dir/compiled/lib/app.js")
        expect(assets.write 'lib/app').to eq "compiled/lib/app.js"
      end
    end

    context "no output is set with directory set" do
      it "writes to relative path under directory and returns the relative path" do
        assets.directory = '/tmp/dir'
        expect(asset).to receive(:write_to).with("/tmp/dir/lib/app.js")
        expect(assets.write 'lib/app').to eq 'lib/app.js'
      end
    end

    context "no output is set with no directory set" do
      it "writes to relative path and returns the relative path" do
        expect(asset).to receive(:write_to).with('lib/app.js')
        expect(assets.write 'lib/app').to eq 'lib/app.js'
      end
    end

    context "when gzip true" do
      it "still returns the non-gzipped asset 'lib/app.js'" do
        allow(asset).to receive(:write_to)
        expect(assets.write 'lib/app', gzip: true).to eq 'lib/app.js'
      end

      it "it gzips the assets as well" do
        expect(asset).to receive(:write_to).at_most(:once).with("lib/app.js.gz", compress: true)
        expect(asset).to receive(:write_to).at_most(:once).with('lib/app.js')
        assets.write 'lib/app', gzip: true
      end
    end

    context "when hash true" do
      it "hashes the file name" do
        allow(asset).to receive(:digest_path).and_return('lib/app-cb5a921a4e7663347223c41cd2fa9e11.js')
        expect(asset).to receive(:write_to).with('lib/app-cb5a921a4e7663347223c41cd2fa9e11.js')
        assets.write 'lib/app', hash: true
      end
    end
  end

  describe "#find_tags" do
    it "uses the type as the type" do
      assets.type = :javascript
      expect(Palimpsest::Assets).to receive(:find_tags).with(anything, :javascript, anything)
      assets.find_tags path: '/the/path'
    end

    it "uses the options as the options" do
      expect(Palimpsest::Assets).to receive(:find_tags).with(anything, anything, assets.options)
      assets.find_tags path: '/the/path'
    end

    it "uses the directory as the path" do
      assets.directory = '/the/directory'
      expect(Palimpsest::Assets).to receive(:find_tags).with('/the/directory', anything, anything)
      assets.find_tags
    end

    it "can use an alternative path" do
      assets.directory = '/the/directory'
      expect(Palimpsest::Assets).to receive(:find_tags).with('/the/path', anything, anything)
      assets.find_tags path: '/the/path'
    end
  end

  describe "#update_source and #update_source!" do
    let(:asset) { double Sprockets::Asset }

    let(:source) do
      <<-EOF
        <head>
          <script src="[% javascript app %]"></script>
          <script src="[% javascript vendor/modernizr %]"></script>
          <script>
            [% javascript inline vendor/tracking %]
          </script>
        </head>
      EOF
    end

    let(:result) do
      <<-EOF
        <head>
          <script src="app-1234.js"></script>
          <script src="vendor/modernizr-5678.js"></script>
          <script>
            alert('track');
          </script>
        </head>
      EOF
    end

    let(:result_with_cdn) do
      <<-EOF
        <head>
          <script src="https://cdn.example.com/app-1234.js"></script>
          <script src="https://cdn.example.com/vendor/modernizr-5678.js"></script>
          <script>
            alert('track');
          </script>
        </head>
      EOF
    end

    before :each do
      assets.type = :javascripts
      allow(assets).to receive(:write).with('app').and_return('app-1234.js')
      allow(assets).to receive(:write).with('vendor/modernizr').and_return('vendor/modernizr-5678.js')
      allow(assets.assets).to receive(:[]).with('vendor/tracking').and_return(asset)
      allow(asset).to receive(:to_s).and_return("alert('track');")
    end

    describe "#update_source!" do
      it "replaces asset tags in sources" do
        assets.update_source! source
        expect(source).to eq result
      end

      context "cdn option set" do
        it "uses cdn when it replaces asset tags in sources" do
          assets.options cdn: 'https://cdn.example.com/'
          assets.update_source! source
          expect(source).to eq result_with_cdn
        end
      end
    end

    describe "#update_source" do
      it "replaces asset tags in sources" do
        expect(assets.update_source source).to eq result
      end

      it "does not change input string" do
        assets.update_source source
        expect(source).to eq source
      end
    end
  end

  describe ".find_tags" do
    context "when grep is the backend" do
      let(:regex) { '\[%(.*?)%\]' }

      it "greps in the path" do
        expect(utils).to receive(:search_files).with(regex, '/the/path', backend: :grep)
        Palimpsest::Assets.find_tags '/the/path', nil, search_backend: :grep
      end

      it "greps for only the asset tag for the given type" do
        expect(utils).to receive(:search_files).with('\[%\s+javascript\s+(.*?)%\]', '/the/path', backend: :grep)
        Palimpsest::Assets.find_tags '/the/path', :javascript, search_backend: :grep
      end

      it "merges options" do
        expect(utils).to receive(:search_files).with('\(%\s+javascript\s+(.*?)%\]', '/the/path', backend: :grep)
        Palimpsest::Assets.find_tags '/the/path', :javascript, src_pre: '(%', search_backend: :grep
      end
    end
  end
end
