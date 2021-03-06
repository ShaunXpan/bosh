require 'fileutils'
require 'tmpdir'
require 'bosh/director'

module Bosh::Director
  class CompiledReleaseDownloader
    def initialize(compiled_packages_group, jobs, blobstore_client)
      @compiled_packages_group = compiled_packages_group
      @jobs = jobs
      @blobstore_client = blobstore_client
    end

    def download
      @download_dir = Dir.mktmpdir

      path = File.join(@download_dir, 'compiled_packages')
      FileUtils.mkpath(path)

      compiled_packages = @compiled_packages_group.compiled_packages
      event_log_stage = event_log.begin_stage("copying packages", compiled_packages.count)

      compiled_packages.each do |compiled_package|
        desc = "#{compiled_package.package.name}/#{compiled_package.package.version}"
        event_log_stage.advance_and_track(desc) do
          blobstore_id = compiled_package.blobstore_id
          File.open(File.join(path, "#{compiled_package.package.name}.tgz"), 'w') do |f|
            @blobstore_client.get(blobstore_id, f, sha1: compiled_package.sha1)
          end
        end
      end

      path = File.join(@download_dir, 'jobs')
      FileUtils.mkpath(path)

      event_log_stage = event_log.begin_stage("copying jobs", @jobs.count)
      @jobs.each do |job|
        desc = "#{job.name}/#{job.version}"
        event_log_stage.advance_and_track(desc) do
          blobstore_id = job.blobstore_id
          File.open(File.join(path, "#{job.name}.tgz"), 'w') do |f|
            @blobstore_client.get(blobstore_id, f, sha1: job.sha1)
          end
        end
      end

      @download_dir
    end

    def cleanup
      FileUtils.rm_rf(@download_dir)
    end

    def event_log
      @event_log ||= Config.event_log
    end

  end
end
