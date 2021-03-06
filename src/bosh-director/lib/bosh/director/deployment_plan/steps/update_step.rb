module Bosh::Director
  module DeploymentPlan
    module Steps
      class UpdateStep
        def initialize(base_job, deployment_plan, multi_job_updater, dns_encoder)
          @base_job = base_job
          @logger = base_job.logger
          @deployment_plan = deployment_plan
          @multi_job_updater = multi_job_updater
          @dns_encoder = dns_encoder
        end

        def perform
          begin
            @logger.info('Updating deployment')
            PreCleanupStep.new(@logger, @deployment_plan).perform
            UpdateActiveVmCpisStep.new(@logger, @deployment_plan).perform
            setup_step.perform
            DownloadPackagesStep.new(@base_job, @deployment_plan).perform
            UpdateJobsStep.new(@base_job, @deployment_plan, @multi_job_updater).perform
            UpdateErrandsStep.new(@base_job, @deployment_plan).perform
            @logger.info('Committing updates')
            PersistDeploymentStep.new(@deployment_plan).perform
            @logger.info('Finished updating deployment')
          ensure
            CleanupStemcellReferencesStep.new(@deployment_plan).perform
          end
        end

        private

        def vm_creator
          return @vm_creator if @vm_creator
          template_blob_cache = @deployment_plan.template_blob_cache
          agent_broadcaster = AgentBroadcaster.new
          disk_manager = DiskManager.new(@logger)
          vm_deleter = Bosh::Director::VmDeleter.new(@logger, false, Config.enable_virtual_delete_vms)
          @vm_creator = Bosh::Director::VmCreator.new(@logger, vm_deleter, disk_manager, template_blob_cache, @dns_encoder, agent_broadcaster)
        end

        def setup_step
          local_dns_repo = LocalDnsRepo.new(@logger, Config.root_domain)
          dns_publisher = BlobstoreDnsPublisher.new(
            lambda { App.instance.blobstores.blobstore },
            Config.root_domain,
            AgentBroadcaster.new,
            @dns_encoder,
            @logger
          )
          SetupStep.new(@base_job, @deployment_plan, vm_creator, local_dns_repo, dns_publisher)
        end
      end
    end
  end
end
