using Bio.Seq: BioSequence, DNASequence, DNAAlphabet, DNAKmer, canonical, FASTASeqRecord, FASTAReader, each, neighbors
using DataStructures: DefaultDict
import GZip
import JLD: load, save
import FileIO: File, @format_str
import Blosc
using OpenGene: fastq_open, fastq_read
include("db_graph.jl")

function check_files(files)
  dont_exist = [file for file in files if !isfile(file)]
  if length(dont_exist) > 0
    Lumberjack.warn("The following input file(s) could not be found: $(join(dont_exist,',')), aborting ...")
    exit(-1)
  end
end

function complement_alleles(vector, m)
  comp_vector = Int16[]
  expected::Int16 = 1
  i::Int16 = 1
  l::Int16 = length(vector)
  while i <= l
    diff = vector[i] - expected
    if diff < 0
      i += 1
      continue
    end
    while diff > 0
      push!(comp_vector, expected)
      expected += 1
      diff -= 1
    end
    i += 1
    expected +=1
  end
  while expected <= m
    push!(comp_vector, expected)
    expected += 1
  end
  return comp_vector
end

function combine_loci_classification(k, results, loci)
  # Arrays to store the kmer classification votes:
  # all kmers in one big list:
  kmer_list = String[]

  # list with elements n1, l1, n2, l2, ..., where n1 is the number of kmers on
  # the kmer_list that corresponds to the the locus l1
  loci_list = Int32[]

  # +1 and -1 corresponding to the weight of the kmer:
  # weight_list = Int8[]
  weight_list = Int16[]

  # n1, a_1, ..., a_n1, n2, b_1, ..., b_n2, ...
  # n1 is the number of alleles corresponding to the next kmer, a_1,...,a_n1 are
  # the alleles getting the vote for the kmer;
  alleles_list = Int16[]

  # Store the allele ids for each locus; In the DB, we index the alleles from 1 to n,
  # so we have to store the original ID to translate back in the output:
  # same format as alleles list: a list size (# of alleles), then the list of alleles;
  allele_ids_per_locus = Int[]

  # locus to int.
  l2int = Dict{String,Int16}(locus => idx for (idx, locus) in enumerate(loci))
  # weight::Int8 = 0
  weight::Int16 = 0

  for (locus,kmer_class, allele_ids, kmer_weights) in results
    n_alleles = length(allele_ids)
    half = n_alleles/2
    n_kmers_in_class = 0
    for (kmer, allele_list) in kmer_class
      l_as = length(allele_list)
      if l_as == n_alleles
        continue
      elseif l_as > half
        allele_list = complement_alleles(allele_list, n_alleles)
        if isempty(allele_list)
          continue
        end
        weight = -get(kmer_weights, kmer, 1)
      else
        weight = get(kmer_weights, kmer, 1)
      end
      push!(kmer_list, "$kmer")
      push!(weight_list, weight)
      push!(alleles_list, length(allele_list))
      append!(alleles_list, allele_list)
      n_kmers_in_class += 1
    end
    push!(loci_list, n_kmers_in_class)
    push!(loci_list, l2int[locus])
    push!(allele_ids_per_locus, n_alleles)
    append!(allele_ids_per_locus, allele_ids)
  end
  return (loci_list, weight_list, alleles_list, kmer_list, allele_ids_per_locus)
end

function kmer_class_for_each_locus(k::Int8, files::Vector{String}, compress::Bool)
  results = []
  loci = String[]
  for file in files
    locus::String = splitext(basename(file))[1]
    push!(loci, locus)
    kmer_class, allele_ids, kmer_weights = build_db_graph(DNAKmer{k}, file)
    push!(results, (locus,kmer_class, allele_ids, kmer_weights))
  end
  return results, loci
end

function save_db(k, kmer_db, loci, filename, profile, args)

  loci_list, weight_list, alleles_list, kmer_list, allele_ids_per_locus = kmer_db
  d = Dict(
    "loci_list"=> Blosc.compress(loci_list),
    "weight_list" => Blosc.compress(weight_list),
    "allele_ids_per_locus" => Blosc.compress(allele_ids_per_locus),
    "kmer_list" => join(kmer_list,""),
    "loci"=>loci,
    "args"=>JSON.json(args)
  )
  # alleles list: potentially larger than 2G, so check limit:
  limit = floor(Int,2000000000/sizeof(alleles_list[1])) # Blosc limit is 2147483631, slightly less than 2G (2147483648). Using 2000000000 just to make it easier on the eye. :)
  if sizeof(alleles_list) <= limit
    d["alleles_list"] = Blosc.compress(alleles_list)
  else
    # we have to break this into smaller chunks:
    n_chunks = ceil(Int, length(alleles_list)/limit)
    l = length(alleles_list)
    for i = 0:n_chunks-1
      name = "alleles_list_$i"
      s = i*limit + 1
      e = min((i+1)*limit,l)
      d[name] = Blosc.compress(alleles_list[s:e])
    end
  end
  # mkdir:
  mkpath(dirname(filename))
  # database:
  JLD.save(File(format"JLD", "$filename"), d)
  # Profile:
  if profile != nothing
    cp(profile, "$filename.profile", remove_destination=true)
  end
end
function open_db(filename)
  # profile:
  profile = nothing
  if isfile("$filename.profile")
    types = Array{String}[]
    open("$filename.profile") do f
      header = split(readline(f),"\t")
      for l in eachline(f)
        values = split(strip(l),"\t")
        push!(types, values)
      end
      profile = Dict("header"=>header, "types"=>types)
    end
  end

  # Compressed database, open and decompress/decode in memory:
  d = JLD.load("$filename")
  # alleles_list might be split into smaller parts:
  alleles_list = []
  if haskey(d, "alleles_list")
    alleles_list = Blosc.decompress(Int16, d["alleles_list"])
  else
    idx = 0
    while haskey(d, "alleles_list_$idx")
      append!(alleles_list,Blosc.decompress(Int16, d["alleles_list_$idx"]))
      idx += 1
    end
  end
  build_args = JSON.parse(d["args"])
  k = build_args["k"]
  loci = d["loci"]
  loci_list = Blosc.decompress(Int32, d["loci_list"])
  # weight_list = Blosc.decompress(Int8, d["weight_list"])
  weight_list = Blosc.decompress(Int16, d["weight_list"])
  allele_ids_per_locus = Blosc.decompress(Int, d["allele_ids_per_locus"])
  kmer_str = d["kmer_list"]
  # build a dict to transform allele idx (1,2,...) to original allele ids:
  loci2alleles = Dict{Int16, Vector{Int16}}(idx => Int16[] for (idx,locus) in enumerate(loci))
  allele_ids_idx = 1
  locus_idx = 1
  while allele_ids_idx < length(allele_ids_per_locus)
    n_alleles = allele_ids_per_locus[allele_ids_idx]
    append!(loci2alleles[locus_idx], allele_ids_per_locus[allele_ids_idx+1:allele_ids_idx + n_alleles])
    allele_ids_idx += 1 + n_alleles
    locus_idx += 1
  end
  # build the kmer db in the usual format:
  kmer_classification = DefaultDict{DNAKmer{k}, Vector{Tuple{Int16, Int16, Vector{Int16}}}}(() -> Vector{Tuple{Int16, Int16, Vector{Int16}}}())
  # tuple is locus idx, weight, and list of alleles;
  loci_list_idx = 1
  allele_list_idx = 1
  kmer_idx = 1
  weight_idx = 1
  # for each loci, the number of kmers and the locus idx;
  while loci_list_idx < length(loci_list)
    n_kmers = loci_list[loci_list_idx]
    locus_idx = loci_list[loci_list_idx+1]
    loci_list_idx += 2
    for i in 1:n_kmers
      # get current kmer
      kmer = DNAKmer{k}(kmer_str[kmer_idx:kmer_idx+k-1])
      kmer_idx += k
      # get list of alleles for this kmer:
      n_alleles = alleles_list[allele_list_idx]
      current_allele_list = alleles_list[allele_list_idx+1:allele_list_idx+n_alleles]
      allele_list_idx += n_alleles + 1
      weight = weight_list[weight_idx]
      weight_idx += 1
      # save in db
      push!(kmer_classification[kmer], (locus_idx, weight, current_allele_list))
    end
  end
  return kmer_classification, loci, loci2alleles, k, profile, build_args
end

function _find_profile(alleles, profile)
  if profile == nothing
    return 0,0
  end
  l = length(alleles)
    alleles_str = map(string,alleles)
  for genotype in profile["types"]
    # first element is the type id, all the rest is the actual genotype:
    if alleles_str == genotype[2:1+l]
      # assuming Clonal Complex after genotype, when present.
      return genotype[1], length(genotype) >= l + 2 ? genotype[l+2] : ""
    end
  end
  return 0,0
end

function read_alleles(fastafile)
  record = FASTASeqRecord{BioSequence{DNAAlphabet{2}}}()
  alleles = String[]
  open(FASTAReader{BioSequence{DNAAlphabet{2}}}, fastafile) do reader
    while !eof(reader)
      read!(reader, record)
      # there might be "\n" on the string, remove and return:
      push!(alleles, join(split("$(record.seq)")))
      # end
    end
  end
  return alleles
end

function call_alleles{k}(::Type{DNAKmer{k}}, kmer_count, votes, loci_votes, loci, loci2alleles, fasta_files, kmer_thr, max_mutations, output_votes)
  allele_calls = String[]
  novel_alleles = Dict{Int, Any}()
  report = []
  alleles_to_check = []
  # For each call, test kmer coverage depth:
  for (idx, locus) in enumerate(loci)
    # 1st - if no locus votes, no presence:
    if loci_votes[idx] == 0
      push!(allele_calls, "0")
      push!(report, (0.0,0,"Not present, no kmers found.")) # Coverage, Minkmer depth, Call
      continue
    end
    sorted_voted_alleles = sort(collect(votes[idx]), by=x->-x[2])
    allele_seqs = read_alleles(fasta_files[idx])
    # TODO: instead of 20 from the sort, something a bit smarter? All within some margin from the best?
    # allele_coverage = [(al, votes, sequence_coverage(DNAKmer{k}, allele_seqs[al], kmer_count, kmer_thr)) for (al, votes) in sorted_voted_alleles[1:min(20,end)]]
    allele_coverage = [(al, votes, sequence_coverage(DNAKmer{k}, allele_seqs[al], kmer_count, kmer_thr)) for (al, votes) in sorted_voted_alleles[1:min(10,end)]]
    # sequence_coverage returns smallest depth of coverage, # kmers covered, # kmers uncovered
    # each element in allele_coverage is then a tuple -> (allele, votes, (depth, # covered, # uncovered))
    # filter to find fully covered alleles :
    covered = [x for x in allele_coverage if (x[3][1] >= kmer_thr)] # if I remove negative votes, I might reconstruct this on the novel anyway; better to flag output
    if length(covered) == 1
      # choose the only fully covered allele
      allele = covered[1][1]
      allele_votes  = covered[1][2]
      depth = covered[1][3][1]
      push!(allele_calls, "$(loci2alleles[idx][allele])")
      warning = allele_votes < 0 ? " Call with negative votes: $allele_votes." : ""
      push!(report, (1, depth, "Called allele $(loci2alleles[idx][allele]).$warning")) # Coverage, Minkmer depth, Call
      continue
    end
    if length(covered) > 1
      # choose the most voted, but indicate that there are more fully covered that might be possible:
      allele = covered[1][1]
      push!(allele_calls, "$(loci2alleles[idx][allele])+")
      multiple_alleles = join([loci2alleles[idx][x[1]] for x in covered],", ")
      multiple_votes = join([x[2] for x in covered],", ")
      multiple_depth = join([x[3][1] for x in covered],", ")
      push!(report, (1, "*", "Multiple possible alleles:$multiple_alleles with depth $multiple_depth and votes $multiple_votes. Most voted ($(loci2alleles[idx][allele])) is chosen on call file.")) # Coverage, Minkmer depth, Call
      # save those alleles:
      for x in covered
        push!(alleles_to_check, (locus, loci2alleles[idx][x[1]], allele_seqs[x[1]], "Multiple alleles present for this locus. Depth:$(x[3][1]) Votes:$(x[2])"))
      end
      continue
    end
    # here, no allele is covered; if the "hole" is small, try novel allele
    # Try to find novel; sort by # of uncovered kmers or % covered
    sorted_allele_coverage = sort(allele_coverage, by=x->x[3][3])
    uncovered_kmers = sorted_allele_coverage[1][3][3]
    covered_kmers = sorted_allele_coverage[1][3][2]
    coverage = covered_kmers / (covered_kmers + uncovered_kmers)
    # each mutation gives around k uncovered kmers, so if smallest_uncovered > k * max_mutations, then declare missing;
    if uncovered_kmers > k * max_mutations # consider not present; TODO: better criteria?
      push!(allele_calls, "0") # not present
      allele = sorted_allele_coverage[1][1]
      depth = sorted_allele_coverage[1][3][1]
      allele_label = loci2alleles[idx][allele]
      # save allele
      push!(alleles_to_check, (locus, loci2alleles[idx][allele], allele_seqs[allele], "Best voted allele, but declared not present, with $uncovered_kmers uncovered kmers and coverage $coverage."))
      push!(report, (round(coverage,4), depth, "Not present; allele $allele_label is the best voted but below threshold with $uncovered_kmers/$(covered_kmers+uncovered_kmers) missing kmers.")) # Coverage, Minkmer depth, Call
      continue
    end

    # otherwise, try to find a novel allele; get the most covered allele as template:
    # println("Locus:$locus Coverage for allele $(sorted_allele_coverage[1][1]), mincov: $(sorted_allele_coverage[1][3][1]):")
    # println("$(["($x,$y)" for (x,y) in sorted_allele_coverage[1][3][4]])")
    # println()


    # New: fill gaps:
    # TODO: is there a point to try more than one allele? they are so similar that is very hard to think that it would change;
    # for current_allele in sorted_allele_coverage[1:5]
      # al, al_votes, (depth, uncov, cov, gap_list) = current_allele
      used_template_allele, al_votes, (depth, uncov, cov, gap_list) = sorted_allele_coverage[1]
      template_seq = allele_seqs[used_template_allele]
      println("Locus:$locus, trying allele $used_template_allele, L:$(length(template_seq)) Gap_list: $gap_list")
      novel_allele_seq, uncorrected_gaps = correct_template(DNAKmer{k}, template_seq, gap_list, kmer_count, kmer_thr, max_mutations)
      # if full
      # TODO: this info in the report
      if length(uncorrected_gaps) == 0
        println("Full novel allele found!")
        println("C:$novel_allele_seq")
      else
        println("Out of the $(length(gap_list)) gaps, the gaps $uncorrected_gaps were not corrected. Using the original allele sequence for those gaps.")
      end
    # end
    # TODO: for now, just save as a novel allele. Later, check if it is not a Partially uncovered allele.
    # TODO: fill correctly the n_mut, events, and var_ab
    n_mut = -1
    events = []
    var_ab = -1
    novel_alleles[idx] = n_mut, used_template_allele, novel_allele_seq, events, var_ab
    push!(allele_calls, "N")
    # report:
    template_allele_label = loci2alleles[idx][used_template_allele]
    mutations_txt = n_mut > 1 ? "mutations" : "mutation"
    mutation_desc = join([describe_mutation(ev) for ev in events], ", ")
    push!(report, (1, var_ab, "Novel, $n_mut $mutations_txt from allele $template_allele_label: $mutation_desc")) # Coverage, Minkmer depth, Call
    # save, closest and novel:
    push!(alleles_to_check, (locus, loci2alleles[idx][used_template_allele], allele_seqs[used_template_allele], "Template for novel allele."))
    push!(alleles_to_check, (locus, "Novel", novel_allele_seq, "$n_mut $mutations_txt from allele $template_allele_label: $mutation_desc"))

    # # OLD:::
    # template_alleles = [sorted_allele_coverage[1][1]]
    # # if there is a tie with other alleles, also include them, up to 10.
    # for i in 2:min(10, length(sorted_allele_coverage))
    #   if sorted_allele_coverage[i][3][3] > uncovered_kmers
    #     break
    #   end
    #   push!(template_alleles, sorted_allele_coverage[i][1])
    # end
    # # try the template(s)
    # try_novel_allele = find_allele_variants(DNAKmer{k}, allele_seqs, template_alleles, kmer_count, kmer_thr, max_mutations)
    # if try_novel_allele != nothing
    #   # found something;
    #   n_mut, used_template_allele, sequence, events, var_ab = try_novel_allele
    #   # sanity check, test if we did not find a novel that is already existing!
    #   if any([sequence == allele_seqs[template_allele] for template_allele in template_alleles])
    #     # not a new allele; TODO: check why
    #     println("******************************** Found the same allele, no novel! -> $(loci[idx])")
    #     # TODO: find the correct covered; now just pick the best voted; this should not happen anyway, if it is, check why.
    #     allele = sorted_voted_alleles[1][1]
    #     push!(allele_calls, "$(loci2alleles[idx][allele])")
    #     depth = sorted_allele_coverage[1][3][1]
    #     push!(report, (1, var_ab, "$(loci2alleles[idx][allele])")) # Coverage, Minkmer depth, Call
    #   else
    #    # found really something new, save the novel allele;
    #     novel_alleles[idx] = try_novel_allele
    #     push!(allele_calls, "N")
    #     # report:
    #     template_allele_label = loci2alleles[idx][used_template_allele]
    #     mutations_txt = n_mut > 1 ? "mutations" : "mutation"
    #     mutation_desc = join([describe_mutation(ev) for ev in events], ", ")
    #     push!(report, (1, var_ab, "Novel, $n_mut $mutations_txt from allele $template_allele_label: $mutation_desc")) # Coverage, Minkmer depth, Call
    #     # save, closest and novel:
    #     push!(alleles_to_check, (locus, loci2alleles[idx][used_template_allele], allele_seqs[used_template_allele], "Template for novel allele."))
    #     push!(alleles_to_check, (locus, "Novel", sequence, "$n_mut $mutations_txt from allele $template_allele_label: $mutation_desc"))
    #
    #   end
    # else
    #   # did not find anything; output allele/N, not sure which;
    #   allele = sorted_allele_coverage[1][1]
    #   depth = sorted_allele_coverage[1][3][1]
    #   allele_label = loci2alleles[idx][allele]
    #   push!(allele_calls, "$allele_label/N?")
    #   push!(report, (round(coverage,4), depth, "Partially covered alelle, novel or not present; Most covered allele $allele_label has $uncovered_kmers/$(covered_kmers+uncovered_kmers) missing kmers, and no novel was found.")) # Coverage, Minkmer depth, Call
    #   push!(alleles_to_check, (locus, loci2alleles[idx][allele], allele_seqs[allele], "Uncovered, novel or not present; Allele $allele_label has $uncovered_kmers/$(covered_kmers+uncovered_kmers) missing kmers, and no novel was found."))
    # end

  end # end of per locus loop to call;

  # Also do voting output?
  if output_votes
    ties = DefaultDict{String,Vector{Int16}}(() -> Int16[])
    vote_log = []
    best_voted_alleles = []
    for (idx,locus) in enumerate(loci)
      # if locus has no votes (no kmer present), output a zero:
      if loci_votes[idx] == 0
        push!(best_voted_alleles, "0")
        continue
      end
      # if it has votes, sort and pick the best;
      sorted_vote = sort(collect(votes[idx]), by=x->-x[2])
      push!(best_voted_alleles, loci2alleles[idx][sorted_vote[1][1]])
      votes_txt = join(["$(loci2alleles[idx][al])($votes)" for (al,votes) in sorted_vote[1:min(20,end)]],",")
      push!(vote_log, (loci_votes[idx], votes_txt))
      # find if there was a tie:
      if length(sorted_vote) > 1 && sorted_vote[1][2] == sorted_vote[2][2] # there is a tie;
        for i in 1:length(sorted_vote)
          if sorted_vote[i][2] < sorted_vote[1][2]
            break
          end
          push!(ties[locus], sorted_vote[i][1])
        end
      end
    end
    voting_result = best_voted_alleles, vote_log, ties
  else
    voting_result = nothing
  end

  return allele_calls, novel_alleles, report, alleles_to_check, voting_result
end

function write_calls{k}(::Type{DNAKmer{k}}, loci2alleles, allele_calls, novel_alleles, report, alleles_to_check, loci, voting_result, sample, filename, profile, output_special_cases)
  # write the main call:
  st, clonal_complex = _find_profile(allele_calls, profile)
  open(filename, "w") do f
    header = join(vcat(["Sample"], loci, ["ST", "clonal_complex"]), "\t")
    write(f,  "$header\n")
    calls = join(vcat([sample], allele_calls, ["$st", clonal_complex]), "\t")
    write(f, "$calls\n")
  end
  # write the call report:
  open("$filename.coverage.txt", "w") do f
    write(f, "Locus\tCoverage\tMinKmerDepth\tCall\n")
    for (locus, data) in zip(loci, report)
      write(f, "$locus\t$(join(data,'\t'))\n")
    end
  end
  # write the alleles with novel, missing, or multiple calls:
  if output_special_cases && length(alleles_to_check) > 0
    open("$filename.special_cases.fa", "w") do f
      for (locus, al, seq, desc) in alleles_to_check
        write(f,">$(locus)_$al $desc\n$seq\n")
      end
    end
  end
  # write novel alleles:
  if length(novel_alleles) > 0
    open("$filename.novel.fa", "w") do fasta
      open("$filename.novel.txt", "w") do text
        write(text, "Loci\tMinKmerDepth\tNmut\tDesc\n")
        for (idx, novel_allele) in sort(collect(novel_alleles), by=x->x[1])
          n_mut, template_idx, seq, events, abundance = novel_allele
          write(fasta, ">$(loci[idx])\n$seq\n")
          mutation_desc = join([describe_mutation(ev) for ev in events], ", ")
          write(text, "$(loci[idx])\t$abundance\t$n_mut\tFrom allele $(loci2alleles[idx][template_idx]), $mutation_desc.\n")
        end
      end
    end
  end
  # write also the votes is we got them:
  if voting_result != nothing
    best_voted_alleles, vote_log, ties = voting_result
    # write the votes call:
    st, clonal_complex = _find_profile(best_voted_alleles, profile)
    open("$filename.byvote", "w") do f
      header = join(vcat(["Sample"], loci, ["ST", "clonal_complex"]), "\t")
      write(f,  "$header\n")
      calls = join(vcat([sample], best_voted_alleles, ["$st", clonal_complex]), "\t")
      write(f, "$calls\n")
    end
    # write the detailed votes:
    open("$filename.votes.txt", "w") do f
      write(f, "Locus\tTotalLocusVotes\tAllele(votes),...\n")
      for (locus, data) in zip(loci, vote_log)
        write(f, "$locus\t$(join(data,'\t'))\n")
      end
    end

    # write ties:
    if length(ties) > 0
      open("$filename.ties.txt", "w") do f
        for (locus, tied_alleles) in sort(collect(ties), by=x->x[1])
          ties_txt = join(["$t" for t in tied_alleles],", ")
          write(f, "$locus\t$ties_txt\n")
        end
      end
    end
  end

end

function count_kmers_in_db_only{k}(::Type{DNAKmer{k}}, files, kmer_db)
  # Count kmers:
  kmer_count = DefaultDict{DNAKmer{k},Int}(0)
  for f in files
    istream = fastq_open(f)
    while (fq = fastq_read(istream))!=false
      for (pos, kmer) in each(DNAKmer{k}, DNASequence(fq.sequence.seq), 1)
        kmer = canonical(kmer)
        if haskey(kmer_db, kmer)
          kmer_count[kmer] += 1
        end
      end
    end
  end
  return kmer_count
end

function count_kmers{k}(::Type{DNAKmer{k}}, files)
  # Count kmers:
  kmer_count = DefaultDict{DNAKmer{k},Int}(0)
  for f in files
    istream = fastq_open(f)
    while (fq = fastq_read(istream))!=false
      for (pos, kmer) in each(DNAKmer{k}, DNASequence(fq.sequence.seq), 1)
        kmer_count[canonical(kmer)] += 1
      end
    end
  end
  return kmer_count
end

function count_votes(kmer_count, kmer_db, loci2alleles)
# function count_kmers_and_vote{k}(::Type{DNAKmer{k}}, files, kmer_db, loci2alleles)
  # Now count votes:
  # 0 votes for all alleles everyone at the start:
  votes = Dict(locus_idx => Dict{Int16, Int}(i => 0 for i in 1:length(alleles)) for (locus_idx,alleles) in loci2alleles)
  # votes per locus, to decide presence/absence:
  loci_votes = DefaultDict{Int16, Int}(0)
  for (kmer, count) in kmer_count
    if haskey(kmer_db, kmer)
      for (locus, weight, alleles) in kmer_db[kmer]
        v = weight * count
        loci_votes[locus] += abs(v)
        for allele in alleles
          votes[locus][allele] += v
        end
      end
    end
  end
  return votes, loci_votes
end
