// -*- mode: c++; tab-width: 2; indent-tabs-mode: nil -*-
#include <iostream>

#include "common/god.h"
#include "common/sentences.h"
#include "common/search.h"

#include "encoder_decoder.h"
#include "gpu/mblas/matrix_functions.h"
#include "gpu/dl4mt/dl4mt.h"
#include "gpu/decoder/encoder_decoder_state.h"
#include "gpu/decoder/best_hyps.h"

using namespace std;

namespace amunmt {
namespace GPU {

///////////////////////////////////////////////////////////////////////////////
EncoderDecoder::EncoderDecoder(
        const God &god,
        const std::string& name,
        const YAML::Node& config,
        size_t tab,
        const Weights& model,
        const Search &search)
: Scorer(god, name, config, tab, search),
  model_(model),
  encoder_(new Encoder(model_)),
  decoder_(new Decoder(god, model_)),
  indices_(god.Get<size_t>("beam-size")),
  encDecBuffer_(3)

{
  std::thread *thread = new std::thread( [&]{ DecodeAsync(god); });
  decThread_.reset(thread);

}

EncoderDecoder::~EncoderDecoder()
{
  decThread_->join();
}

State* EncoderDecoder::NewState() const {
  return new EDState();
}

void EncoderDecoder::Encode(const SentencesPtr source) {
  BEGIN_TIMER("Encode");

  mblas::EncParamsPtr encParams(new mblas::EncParams());
  encParams->sentences = source;

  if (source->size()) {
    encoder_->Encode(*source, tab_, encParams);
  }

  encDecBuffer_.add(encParams);
  //cerr << "Encode encParams->sourceContext_=" << encParams->sourceContext_.Debug(0) << endl;

  PAUSE_TIMER("Encode");
}

void EncoderDecoder::BeginSentenceState(State& state, size_t batchSize)
{
  mblas::EncParamsPtr encParams = encDecBuffer_.remove();
  BeginSentenceState(state, batchSize, encParams);
}

void EncoderDecoder::BeginSentenceState(State& state, size_t batchSize, mblas::EncParamsPtr encParams)
{
  //cerr << "BeginSentenceState encParams->sourceContext_=" << encParams->sourceContext_.Debug(0) << endl;
  //cerr << "BeginSentenceState encParams->sentencesMask_=" << encParams->sentencesMask_.Debug(0) << endl;
  //cerr << "batchSize=" << batchSize << endl;

  EDState& edState = state.get<EDState>();

  decoder_->EmptyState(edState.GetStates(), encParams, batchSize);

  decoder_->EmptyEmbedding(edState.GetEmbeddings(), batchSize);
}

void EncoderDecoder::Decode(const State& in, State& out, const std::vector<uint>& beamSizes) {
  BEGIN_TIMER("Decode");
  const EDState& edIn = in.get<EDState>();
  EDState& edOut = out.get<EDState>();

  decoder_->Decode(edOut.GetStates(),
                     edIn.GetStates(),
                     edIn.GetEmbeddings(),
                     beamSizes);
  PAUSE_TIMER("Decode");
}


void EncoderDecoder::DecodeAsync(const God &god)
{
  while (true) {
    mblas::EncParamsPtr encParams = encDecBuffer_.remove();
    assert(encParams.get());
    assert(encParams->sentences.get());

    if (encParams->sentences->size() == 0) {
      return;
    }

    //cerr << "BeginSentenceState encParams->sourceContext_=" << encParams->sourceContext_.Debug(0) << endl;
    try {
      DecodeAsync(god, encParams);
    }
    catch(thrust::system_error &e)
    {
      std::cerr << "CUDA error during some_function: " << e.what() << std::endl;
      abort();
    }
    catch(std::bad_alloc &e)
    {
      std::cerr << "Bad memory allocation during some_function: " << e.what() << std::endl;
      abort();
    }
    catch(std::runtime_error &e)
    {
      std::cerr << "Runtime error during some_function: " << e.what() << std::endl;
      abort();
    }
    catch(...)
    {
      std::cerr << "Some other kind of error during some_function" << std::endl;
      abort();
    }
  }
}

void EncoderDecoder::DecodeAsync(const God &god, mblas::EncParamsPtr encParams)
{
  boost::timer::cpu_timer timer;

  // begin decoding - create 1st decode states
  State *state = NewState();
  BeginSentenceState(*state, encParams->sentences->size(), encParams);

  State *nextState = NewState();
  std::vector<uint> beamSizes(encParams->sentences->size(), 1);

  Histories histories(*encParams->sentences, search_.NormalizeScore());
  Beam prevHyps = histories.GetFirstHyps();

  // decode
  for (size_t decoderStep = 0; decoderStep < 3 * encParams->sentences->GetMaxLength(); ++decoderStep) {
    cerr << "\ndecoderStep=" << decoderStep << endl;
    //cerr << "beamSizes0=" << Debug(beamSizes, 2) << endl;
    Decode(*state, *nextState, beamSizes);
    //cerr << "beamSizes1=" << Debug(beamSizes, 2) << endl;

    // beams
    if (decoderStep == 0) {
      for (auto& beamSize : beamSizes) {
        beamSize = search_.MaxBeamSize();
      }
    }

    //cerr << "beamSizes2=" << Debug(beamSizes, 2) << endl;
    size_t batchSize = beamSizes.size();
    Beams beams(batchSize);
    search_.BestHyps()->CalcBeam(prevHyps, *this, search_.FilterIndices(), beams, beamSizes);
    //cerr << "beamSizes3=" << Debug(beamSizes, 2) << endl;
    histories.Add(beams);

    Beam survivors;
    for (size_t batchId = 0; batchId < batchSize; ++batchId) {
      for (const HypothesisPtr& h : beams[batchId]) {
        if (h->GetWord() != EOS_ID) {
          survivors.push_back(h);
        } else {
          --beamSizes[batchId];
        }
      }
    }

    cerr << "beamSizes4=" << Debug(beamSizes, 2) << endl;
    cerr << "beams=" << beams.size() << endl;
    cerr << "survivors=" << survivors.size() << endl;
    cerr << "histories=" << histories.size() << endl;

    if (survivors.size() == 0) {
      break;
    }

    AssembleBeamState(*nextState, survivors, *state);

    prevHyps.swap(survivors);

  }

  CleanUpAfterSentence();

  // output
  Output(god, histories);

  LOG(progress)->info("Decoding took {}", timer.format(3, "%ws"));
}

void EncoderDecoder::Output(const God &god, const Histories &histories)
{
  for (size_t i = 0; i < histories.size(); ++i) {
    const History &history = *histories.at(i);
    Output(god, history);
  }
}

void EncoderDecoder::Output(const God &god, const History &history)
{
  OutputCollector &outputCollector = god.GetOutputCollector();

  size_t lineNum = history.GetLineNum();
  //cerr << "lineNum=" << lineNum << endl;

  std::stringstream strm;
  history.Printer(god, strm);

  outputCollector.Write(lineNum, strm.str());
}

void EncoderDecoder::AssembleBeamState(const State& in,
                               const Beam& beam,
                               State& out) {
  std::vector<size_t> beamWords;
  std::vector<uint> beamStateIds;
  for (const HypothesisPtr &h : beam) {
     beamWords.push_back(h->GetWord());
     beamStateIds.push_back(h->GetPrevStateIndex());
  }
  //cerr << "beamWords=" << Debug(beamWords, 2) << endl;
  //cerr << "beamStateIds=" << Debug(beamStateIds, 2) << endl;

  const EDState& edIn = in.get<EDState>();
  EDState& edOut = out.get<EDState>();
  indices_.resize(beamStateIds.size());
  HostVector<uint> tmp = beamStateIds;

  mblas::copy(thrust::raw_pointer_cast(tmp.data()),
      beamStateIds.size(),
      thrust::raw_pointer_cast(indices_.data()),
      cudaMemcpyHostToDevice);
  //cerr << "indices_=" << mblas::Debug(indices_, 2) << endl;

  mblas::Assemble(edOut.GetStates(), edIn.GetStates(), indices_);
  //cerr << "edOut.GetStates()=" << edOut.GetStates().Debug(1) << endl;

  //cerr << "beamWords=" << Debug(beamWords, 2) << endl;
  decoder_->Lookup(edOut.GetEmbeddings(), beamWords);
  //cerr << "edOut.GetEmbeddings()=" << edOut.GetEmbeddings().Debug(1) << endl;
}

void EncoderDecoder::GetAttention(mblas::Matrix& Attention) {
  decoder_->GetAttention(Attention);
}

BaseMatrix& EncoderDecoder::GetProbs() {
  return decoder_->GetProbs();
}

mblas::Matrix& EncoderDecoder::GetAttention() {
  return decoder_->GetAttention();
}

size_t EncoderDecoder::GetVocabSize() const {
  return decoder_->GetVocabSize();
}

void EncoderDecoder::Filter(const std::vector<size_t>& filterIds) {
  decoder_->Filter(filterIds);
}


}
}

