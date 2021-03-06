

describe DelayedCronJob do

  class TestJob
    def perform; end

    def cron_method(job)
      return nil if job.attempts > 10
      job.attempts % 2 === 0 ? '0 0 1 2 *' : '0 0 1 1 *'
    end
  end

  before { Delayed::Job.delete_all }

  let(:cron)    { '5 1 * * *' }
  let(:handler) { TestJob.new }
  let(:job)     { Delayed::Job.enqueue(handler, cron: cron) }
  let(:worker)  { Delayed::Worker.new }
  let(:now)     { Delayed::Job.db_time_now }
  let(:next_run) do
    run = now.hour * 60 + now.min >= 65 ? now + 1.day : now
    Time.utc(run.year, run.month, run.day, 1, 5)
  end

  context 'with cron' do
    it 'sets run_at on enqueue' do
      expect { job }.to change { Delayed::Job.count }.by(1)
      expect(job.run_at).to eq(next_run)
    end

    it 'enqueue fails with invalid cron' do
      expect { Delayed::Job.enqueue(handler, cron: 'no valid cron') }.
        to raise_error(ArgumentError)
    end

    it 'schedules a new job after success' do
      job.update_column(:run_at, now)
      job.reload

      worker.work_off

      expect(Delayed::Job.count).to eq(1)
      j = Delayed::Job.first
      expect(j.id).to eq(job.id)
      expect(j.cron).to eq(job.cron)
      expect(j.run_at).to eq(next_run)
      expect(j.attempts).to eq(1)
      expect(j.last_error).to eq(nil)
      expect(j.created_at).to eq(job.created_at)
    end

    it 'schedules a new job after failure' do
      allow_any_instance_of(TestJob).to receive(:perform).and_raise('Fail!')
      job.update(run_at: now)
      job.reload

      worker.work_off

      expect(Delayed::Job.count).to eq(1)
      j = Delayed::Job.first
      expect(j.id).to eq(job.id)
      expect(j.cron).to eq(job.cron)
      expect(j.run_at).to eq(next_run)
      expect(j.last_error).to match('Fail!')
      expect(j.created_at).to eq(job.created_at)
    end

    it 'schedules a new job after timeout' do
      Delayed::Worker.max_run_time = 1.second
      job.update_column(:run_at, now)
      allow_any_instance_of(TestJob).to receive(:perform) { sleep 2 }

      worker.work_off

      expect(Delayed::Job.count).to eq(1)
      j = Delayed::Job.first
      expect(j.id).to eq(job.id)
      expect(j.cron).to eq(job.cron)
      expect(j.run_at).to eq(next_run)
      expect(j.attempts).to eq(1)
      expect(j.last_error).to match("execution expired")
    end

    it 'schedules new job after deserialization error' do
      Delayed::Worker.max_run_time = 1.second
      job.update_column(:run_at, now)
      allow_any_instance_of(TestJob).to receive(:perform).and_raise(Delayed::DeserializationError)

      worker.work_off

      expect(Delayed::Job.count).to eq(1)
      j = Delayed::Job.first
      expect(j.last_error).to match("Delayed::DeserializationError")
    end

    it 'has empty last_error after success' do
      job.update(run_at: now, last_error: 'Last error')

      worker.work_off

      j = Delayed::Job.first
      expect(j.last_error).to eq(nil)
    end

    it 'has correct last_error after success' do
      allow_any_instance_of(TestJob).to receive(:perform).and_raise('Fail!')
      job.update(run_at: now, last_error: 'Last error')

      worker.work_off

      j = Delayed::Job.first
      expect(j.last_error).to match('Fail!')
    end

    it 'uses correct db time for next run' do
      if Time.now != now
        job = Delayed::Job.enqueue(handler, cron: '* * * * *')
        run = now.hour == 23 && now.min == 59 ? now + 1.day : now
        hour = now.min == 59 ? (now.hour + 1) % 24 : now.hour
        run_at = Time.utc(run.year, run.month, run.day, hour, (now.min + 1) % 60)
        expect(job.run_at).to eq(run_at)
      else
        pending "This test only makes sense in non-UTC time zone"
      end
    end

    it 'increases attempts on each run' do
      job.update(run_at: now, attempts: 3)

      worker.work_off

      j = Delayed::Job.first
      expect(j.attempts).to eq(4)
    end

    it 'is not stopped by max attempts' do
      job.update(run_at: now, attempts: Delayed::Worker.max_attempts + 1)

      worker.work_off

      expect(Delayed::Job.count).to eq(1)
      j = Delayed::Job.first
      expect(j.attempts).to eq(job.attempts + 1)
    end

    it 'can use dynamic cron' do
      Delayed::Job.enqueue(handler, cron: :cron_method)
      j = Delayed::Job.first
      j.update(run_at: j.run_at.last_year, attempts: 11)

      worker.work_off
    end

    it 'ignores if cron is nil' do
      Delayed::Job.enqueue(handler, cron: :cron_method)

      j = Delayed::Job.first
      expect(j.run_at.month).to eq(2)

      j.update(run_at: j.run_at.last_year)

      worker.work_off
    end 

    it 'does not crash if payload object raises error' do
      allow_any_instance_of(Delayed::Job).to receive(:payload_object).and_raise(Delayed::DeserializationError)
      expect { Delayed::Job.enqueue(handler, cron: :cron_method) }.not_to raise_error
    end
  end

  context 'without cron' do
    it 'reschedules the original job after a single failure' do
      allow_any_instance_of(TestJob).to receive(:perform).and_raise('Fail!')
      job = Delayed::Job.enqueue(handler)

      worker.work_off

      expect(Delayed::Job.count).to eq(1)
      j = Delayed::Job.first
      expect(j.id).to eq(job.id)
      expect(j.cron).to eq(nil)
      expect(j.last_error).to match('Fail!')
    end

    it 'does not reschedule a job after a successful run' do
      Delayed::Job.enqueue(handler)

      worker.work_off

      expect(Delayed::Job.count).to eq(0)
    end
  end
end
