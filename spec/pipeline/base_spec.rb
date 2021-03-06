require 'spec/spec_helper'

module Pipeline
  describe Base do

    context "- configuring" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> SecondStage
        end
      end
      
      it "should allow accessing stages" do
        SamplePipeline.defined_stages.should == [FirstStage, SecondStage]
      end
      
      it "should allow configuring default failure mode (pause by default)" do
        SamplePipeline.default_failure_mode = :pause
        SamplePipeline.failure_mode.should == :pause
        
        SamplePipeline.default_failure_mode = :cancel
        SamplePipeline.failure_mode.should == :cancel
        
        SamplePipeline.default_failure_mode = :something_else
        SamplePipeline.failure_mode.should == :pause
      end
    end
    
    context "- setup" do
      before(:each) do
        @pipeline = SamplePipeline.new
      end
      
      it "should start with status not_started" do
        @pipeline.status.should == :not_started
      end
      
      it "should instantiate stages with status not_started" do
        @pipeline.stages.each { |stage| stage.status.should == :not_started }
      end
      
      it "should validate status" do
        lambda {Base.new(:status => :something_else)}.should raise_error
      end
    end

    context "- persistence" do
      before(:each) do
        @pipeline = Base.new
      end
      
      it "should persist pipeline instance" do
        @pipeline.should be_new_record
        lambda {@pipeline.save!}.should_not raise_error
        @pipeline.should_not be_new_record
      end
      
      it "should allow retrieval by id" do
        @pipeline.save!
        
        retrieved_pipeline = Base.find(@pipeline.id.to_s)
        retrieved_pipeline.should === @pipeline
        
        lambda {Base.find('invalid_id')}.should raise_error(ActiveRecord::RecordNotFound)
      end

      it "should persist type as single table inheritance" do
        pipeline = SamplePipeline.new
        pipeline.save!
        
        retrieved_pipeline = Base.find(pipeline.id)
        retrieved_pipeline.should be_an_instance_of(SamplePipeline)
      end
      
      it "should persist pipeline stages" do
        pipeline = SamplePipeline.new
        pipeline.stages.each {|stage| stage.id.should be_nil}
        lambda {pipeline.save!}.should_not raise_error
        pipeline.stages.each {|stage| stage.id.should_not be_nil}
      end
      
      it "should allow retrieval of stages with pipeline instance" do
        pipeline = SamplePipeline.new
        pipeline.save!
        
        retrieved_pipeline = SamplePipeline.find(pipeline.id)
        retrieved_pipeline.stages.should === pipeline.stages
      end

      it "should associate stages with pipeline instance" do
        pipeline = SamplePipeline.new
        pipeline.save!
        
        pipeline.stages.each {|stage| stage.pipeline.should === pipeline}
      end
      
      it "should destroy stages when pipeline instance is destroyed" do
        pipeline = SamplePipeline.new
        pipeline.save!
        
        Pipeline::Stage::Base.count(:conditions => ['pipeline_instance_id = ?', pipeline.id]).should > 0
        
        pipeline.destroy
        Pipeline::Stage::Base.count(:conditions => ['pipeline_instance_id = ?', pipeline.id]).should == 0
      end
    end
    
    context "- execution (success)" do
      before(:each) do
        @pipeline = SamplePipeline.new
      end

      it "should increment attempts" do
        @pipeline.attempts.should == 0
        @pipeline.perform
        @pipeline.attempts.should == 1
      end
      
      it "should perform each stage" do
        @pipeline.stages.each { |stage| stage.should_not be_executed }
        @pipeline.perform
        @pipeline.stages.each { |stage| stage.should be_executed }
      end
      
      it "should update pipeline status after all stages finished" do
        @pipeline.perform
        @pipeline.status.should == :completed
      end
      
      it "should save status" do
        @pipeline.save!
        @pipeline.perform
        @pipeline.reload.status.should == :completed
      end
    end
    
    context "- execution (in progress)" do
      it "should set status to in_progress" do
        pipeline = SamplePipeline.new
        pipeline.send(:_setup)
        
        pipeline.status.should == :in_progress
        pipeline.reload.status.should == :in_progress
      end
    end
    
    context "- execution (irrecoverable error)" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> IrrecoverableStage
        end
        @pipeline = ::SamplePipeline.new
      end

      it "should not re-raise error" do
        lambda {@pipeline.perform}.should_not raise_error(IrrecoverableError)
      end
      
      it "should update status" do
        @pipeline.perform
        @pipeline.status.should == :failed
      end
      
      it "should save status" do
        @pipeline.save!
        @pipeline.perform
        @pipeline.reload.status.should == :failed
      end
    end
    
    context "- execution (recoverable error that doesn't require user input)" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> RecoverableStage
        end
        @pipeline = SamplePipeline.new
      end

      it "should re-raise error (so delayed_job retry works)" do
        lambda {@pipeline.perform}.should raise_error(RecoverableError)
      end
      
      it "should change status to :retry" do
        lambda {@pipeline.perform}.should raise_error(RecoverableError)
        @pipeline.status.should == :retry
      end
      
      it "should save status" do
        @pipeline.save!
        lambda {@pipeline.perform}.should raise_error(RecoverableError)
        @pipeline.reload.status.should == :retry
      end
    end

    context "- execution (recoverable error that requires user input)" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> RecoverableInputRequiredStage
        end
        @pipeline = SamplePipeline.new
      end

      it "should not re-raise error" do
        lambda {@pipeline.perform}.should_not raise_error(RecoverableError)
      end
      
      it "should update status" do
        @pipeline.perform
        @pipeline.status.should == :paused
      end
      
      it "should save status" do
        @pipeline.save!
        @pipeline.perform
        @pipeline.reload.status.should == :paused
      end
    end

    context "- execution (other errors will use failure mode to pause/cancel pipeline)" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> GenericErrorStage
        end
        @pipeline = SamplePipeline.new
      end

      it "should not re-raise error" do
        lambda {@pipeline.perform}.should_not raise_error(Exception)
      end
      
      it "should update status (pause mode)" do
        SamplePipeline.default_failure_mode = :pause
        @pipeline.perform
        @pipeline.status.should == :paused
      end
      
      it "should save status (pause mode)" do
        SamplePipeline.default_failure_mode = :pause
        @pipeline.save!
        @pipeline.perform
        @pipeline.reload.status.should == :paused
      end

      it "should update status (cancel mode)" do
        SamplePipeline.default_failure_mode = :cancel
        @pipeline.perform
        @pipeline.status.should == :failed
      end
      
      it "should save status (cancel mode)" do
        SamplePipeline.default_failure_mode = :cancel
        @pipeline.save!
        @pipeline.perform
        @pipeline.reload.status.should == :failed
      end
    end

    context "- execution (retrying)" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> RecoverableInputRequiredStage
        end
        @pipeline = SamplePipeline.new
      end

      it "should not re-raise error" do
        lambda {@pipeline.perform}.should_not raise_error(RecoverableError)
      end
      
      it "should update status" do
        @pipeline.perform
        @pipeline.status.should == :paused
      end
      
      it "should save status" do
        @pipeline.save!
        @pipeline.perform
        @pipeline.reload.status.should == :paused
      end
      
      it "should skip completed stages" do
        @pipeline.perform
        @pipeline.stages[0].attempts.should == 1
        @pipeline.stages[1].attempts.should == 1
        
        @pipeline.perform
        @pipeline.stages[0].attempts.should == 1
        @pipeline.stages[1].attempts.should == 2
      end
      
      it "should refresh object (in case it was cancelled after job was scheduled)" do
        # Gets paused on the first time
        @pipeline.save!
        @pipeline.perform
        
        # Status gets updated to failed on the database (not on the current instance)
        same_pipeline = SamplePipeline.find(@pipeline.id)
        same_pipeline.update_attribute(:status, :failed)
        
        # Retrying should fail because pipeline is now failed
        lambda {@pipeline.perform}.should raise_error(InvalidStatusError, "Status is already failed")
      end
    end
    
    context "- execution (state transitions)" do
      before(:each) do
        @pipeline = Base.new
      end
      
      it "should execute if status is :not_started" do
        @pipeline.should be_ok_to_resume
        lambda {@pipeline.perform}.should_not raise_error(InvalidStatusError)
      end

      it "should execute if status is :paused (for retrying)" do
        @pipeline.update_attribute(:status, :paused)
        
        @pipeline.should be_ok_to_resume
        lambda {@pipeline.perform}.should_not raise_error(InvalidStatusError)
      end

      it "should execute if status is :retry" do
        @pipeline.update_attribute(:status, :retry)
        
        @pipeline.should be_ok_to_resume
        lambda {@pipeline.perform}.should_not raise_error(InvalidStatusError)
      end
      
      it "should not execute if status is :in_progress" do
        @pipeline.update_attribute(:status, :in_progress)
        
        @pipeline.should_not be_ok_to_resume
        lambda {@pipeline.perform}.should raise_error(InvalidStatusError, "Status is already in progress")
      end

      it "should not execute if status is :completed" do
        @pipeline.update_attribute(:status, :completed)
        
        @pipeline.should_not be_ok_to_resume
        lambda {@pipeline.perform}.should raise_error(InvalidStatusError, "Status is already completed")
      end

      it "should not execute if status is :failed" do
        @pipeline.update_attribute(:status, :failed)
        
        @pipeline.should_not be_ok_to_resume
        lambda {@pipeline.perform}.should raise_error(InvalidStatusError, "Status is already failed")
      end
    end
    
    context "- cancelling" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> RecoverableInputRequiredStage
        end
        @pipeline = SamplePipeline.new
        @pipeline.perform
      end

      it "should update status" do
        @pipeline.cancel
        @pipeline.status.should == :failed
      end
      
      it "should save status" do
        @pipeline.save!
        @pipeline.cancel
        @pipeline.reload.status.should == :failed
      end
      
      it "should refresh object (in case it was updated after job was scheduled)" do
        # Gets paused on the first time
        @pipeline.save!
        
        # Status gets updated to failed on the database (not on the current instance)
        same_pipeline = SamplePipeline.find(@pipeline.id)
        same_pipeline.update_attribute(:status, :failed)
        
        # Retrying should fail because pipeline is now failed
        lambda {@pipeline.cancel}.should raise_error(InvalidStatusError, "Status is already failed")
      end
      
    end

    context "- cancelling (state transitions)" do
      before(:each) do
        @pipeline = Base.new
      end
      
      it "should cancel if status is :not_started" do
        lambda {@pipeline.cancel}.should_not raise_error(InvalidStatusError)
      end

      it "should cancel if status is :paused (for retrying)" do
        @pipeline.update_attribute(:status, :paused)
        
        lambda {@pipeline.cancel}.should_not raise_error(InvalidStatusError)
      end
      
      it "should not cancel if status is :in_progress" do
        @pipeline.update_attribute(:status, :in_progress)
        
        lambda {@pipeline.cancel}.should raise_error(InvalidStatusError, "Status is already in progress")
      end

      it "should not cancel if status is :completed" do
        @pipeline.update_attribute(:status, :completed)
        
        lambda {@pipeline.cancel}.should raise_error(InvalidStatusError, "Status is already completed")
      end

      it "should not cancel if status is :failed" do
        @pipeline.update_attribute(:status, :failed)
        
        lambda {@pipeline.cancel}.should raise_error(InvalidStatusError, "Status is already failed")
      end
    end

    context "- resuming" do
      before(:each) do
        class ::SamplePipeline
          define_stages FirstStage >> RecoverableInputRequiredStage
        end
        @pipeline = SamplePipeline.new
        @pipeline.perform
      end

      it "should refresh object (in case it was updated after job was scheduled)" do
        # Gets paused on the first time
        @pipeline.save!
        
        # Status gets updated to failed on the database (not on the current instance)
        same_pipeline = SamplePipeline.find(@pipeline.id)
        same_pipeline.update_attribute(:status, :failed)
        
        # Retrying should fail because pipeline is now failed
        lambda {@pipeline.resume}.should raise_error(InvalidStatusError, "Status is already failed")
      end
    end
    
    context "- resuming (state transitions)" do
      before(:each) do
        @pipeline = Base.new
      end
      
      it "should resume if status is :not_started" do
        lambda {@pipeline.resume}.should_not raise_error(InvalidStatusError)
      end

      it "should resume if status is :paused (for retrying)" do
        @pipeline.update_attribute(:status, :paused)
        
        lambda {@pipeline.resume}.should_not raise_error(InvalidStatusError)
      end
      
      it "should not resume if status is :in_progress" do
        @pipeline.update_attribute(:status, :in_progress)
        
        lambda {@pipeline.resume}.should raise_error(InvalidStatusError, "Status is already in progress")
      end

      it "should not resume if status is :completed" do
        @pipeline.update_attribute(:status, :completed)
        
        lambda {@pipeline.resume}.should raise_error(InvalidStatusError, "Status is already completed")
      end

      it "should not resume if status is :failed" do
        @pipeline.update_attribute(:status, :failed)
        
        lambda {@pipeline.resume}.should raise_error(InvalidStatusError, "Status is already failed")
      end
    end
   
    context "- callbacks" do
      before(:each) do
        @pipeline = ::SamplePipeline.new
      end
      
      it "should allow callback before running the pipeline" do
        @pipeline.should_receive(:before_pipeline_callback).once
        @pipeline.perform
      end
      
      it "should allow callback after running the pipeline" do
        @pipeline.should_receive(:after_pipeline_callback).once
        @pipeline.perform
      end
      
      it "should run callback after cancelling a pipeline" do
        @pipeline.should_receive(:after_pipeline_callback).once
        @pipeline.cancel
      end
    end
  end
end
