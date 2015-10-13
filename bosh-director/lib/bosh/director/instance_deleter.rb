module Bosh::Director
  # Coordinates the safe deletion of an instance and all associates resources.
  class InstanceDeleter

    def initialize(ip_provider, dns_manager, options={})
      @ip_provider = ip_provider
      @dns_manager = dns_manager
      @cloud = Config.cloud
      @logger = Config.logger
      @blobstore = App.instance.blobstores.blobstore

      @force = options.fetch(:force, false)
      @keep_snapshots_in_the_cloud = options.fetch(:keep_snapshots_in_the_cloud, false)
    end

    def delete_instance_plan(instance_plan, event_log_stage)
      instance_model = instance_plan.new? ? instance_plan.instance.model : instance_plan.existing_instance

      @logger.info("Deleting instance '#{instance_model}'")

      event_log_stage.advance_and_track(instance_model.to_s) do

        error_ignorer.with_force_check do
          stop(instance_plan)
        end

        vm_deleter.delete_for_instance_plan(instance_plan, skip_disks: true)

        unless instance_model.compilation
          error_ignorer.with_force_check do
            delete_snapshots(instance_model)
          end

          error_ignorer.with_force_check do
            delete_persistent_disks(instance_model.persistent_disks)
          end

          error_ignorer.with_force_check do
            @dns_manager.delete_dns_for_instance(instance_model)
          end

          error_ignorer.with_force_check do
            RenderedJobTemplatesCleaner.new(instance_model, @blobstore, @logger).clean_all
          end
        end

        instance_plan.network_plans.each do |network_plan|
          reservation = network_plan.reservation
          @ip_provider.release(reservation) if reservation.reserved?
        end
        instance_plan.release_all_network_plans

        instance_model.destroy
      end
    end

    def delete_instance_plans(instance_plans, event_log_stage, options = {})
      max_threads = options[:max_threads] || Config.max_threads
      ThreadPool.new(:max_threads => max_threads).wrap do |pool|
        instance_plans.each do |instance_plan|
          pool.process { delete_instance_plan(instance_plan, event_log_stage) }
        end
      end
    end

    private

    def stop(instance_plan)
      stopper = Stopper.new(instance_plan, 'stopped', Config, @logger)
      stopper.stop
    end

    # FIXME: why do we hate dependency injection?
    def error_ignorer
      @error_ignorer ||= ErrorIgnorer.new(@force, @logger)
    end

    # FIXME: why do we hate dependency injection?
    def vm_deleter
      @vm_deleter ||= VmDeleter.new(@cloud, @logger, {force: @force})
    end

    def delete_persistent_disks(persistent_disks)
      persistent_disks.each do |disk|
        @logger.info("Deleting disk: `#{disk.disk_cid}', " +
            "#{disk.active ? "active" : "inactive"}")
        begin
          @cloud.delete_disk(disk.disk_cid)
        rescue Bosh::Clouds::DiskNotFound => e
          @logger.warn("Disk not found: #{disk.disk_cid}")
          raise if disk.active
        end
        disk.destroy
      end
    end

    def delete_snapshots(instance)
      snapshots = instance.persistent_disks.map { |disk| disk.snapshots }.flatten
      Bosh::Director::Api::SnapshotManager.delete_snapshots(snapshots, keep_snapshots_in_the_cloud: @keep_snapshots_in_the_cloud)
    end
  end
end
