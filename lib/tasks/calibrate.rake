require "csv"

# Derive a calibration profile from graded pairs. Experiment form: pairs are
# (this system's latest estimate, the builder's own estimate) per eval job.
# Product form: same derivation from a customer's uploaded estimate + the
# system's run of the same plans, plus grading-form adjustments.
#
#   bin/rails estimator:calibrate USER=email SOURCE_JOBS=hilda,carberry,benecia,constitution
namespace :estimator do
  desc "Derive a builder calibration profile from graded estimate pairs"
  task calibrate: :environment do
    user = User.find_by!(email_address: ENV.fetch("USER_EMAIL"))
    jobs = ENV.fetch("SOURCE_JOBS").split(",")
    config = YAML.load_file(Rails.root.join("eval/projects.yml"))
    names = { "hilda" => [ "Hilda St — Enoggera", 1.29 ], "rosalie" => [ "77 Rosalie St", 1.07 ],
              "carberry" => [ "Carberry St — Grange", 1.04 ], "benecia" => [ "Benecia — Wavell Heights", 1.17 ],
              "constitution" => [ "Constitution St — Windsor", 1.0975 ], "huxham" => [ "17 Huxham Tce — Auchenflower", 1.02 ],
              "carson" => [ "6 Carson — Bathrooms", 1.0 ] }
    reference = User.find_by!(email_address: "david.test@example.com")

    pairs = jobs.map do |proj|
      name, factor = names.fetch(proj)
      theirs = Hash.new(0.0)
      CSV.read(Rails.root.join(config[proj]["baseline"]), headers: true).each do |r|
        next if r["category"] == "__TOTAL__"
        # variations aren't quotable scope; labour blocks are real cost but
        # unmappable to a trade bucket — both poison bucket-level learning
        next if r["category"] =~ /variation|margin|contingency|\bgst\b|labour hours/i
        theirs[TradeBucket.for(r["category"])] += r["human_estimate_total"].to_f
      end
      e = reference.estimates.where("name LIKE ?", "#{name}%").where(status: "completed").order(:id).last
      ours = Hash.new(0.0)
      e.sections.each { |s| ours[TradeBucket.for(s.name)] += s.subtotal.to_f / factor }
      buckets = theirs.keys.index_with { |b| { "ours" => ours[b].round, "theirs" => theirs[b].round } }
      { "job" => proj, "buckets" => buckets }
    end

    profile = CalibrationProfile.derive!(user, pairs, notes: "derived #{Date.today} from #{jobs.join(', ')}")
    puts "Calibrated #{user.email_address}: #{profile.buckets.size} buckets"
    profile.buckets.each { |b, v| puts format("  %-22s %+d%% (n=%d)", b, v["bias_pct"], v["n"]) }
  end
end
