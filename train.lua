
-- This file trains and tests the RNN from a batch loader.
require('nn')
require('options')
require 'utils.misc'
require 'cudnn'

model_utils = require('utils.model_utils')
require('utils.batchloader')
require('utils.textsource')
require 'model.LanguageModel'

-- Parse arguments
local cmd = RNNOption()
g_params = cmd:parse(arg)
torch.manualSeed(1990)

require 'cutorch'
require 'cunn'
require 'rnn'
cutorch.setDevice(g_params.cuda_device)
cutorch.manualSeed(1990)
cudnn.fastest = true
cudnn.benchmark = true

cmd:print_params(g_params)



-- build the torch dataset
local g_dataset = TextSource(g_params.dataset)
local vocab_size = g_dataset:get_vocab_size()
local g_dictionary = g_dataset.dict
-- A data sampler for training and testing
batch_loader = BatchLoader(g_params.dataset, g_dataset)
local word2idx = g_dictionary.symbol_to_index
local idx2word = g_dictionary.index_to_symbol

local x, y = batch_loader:next_batch(2)
local N, T = x:size(1), x:size(2)

local unigrams = g_dataset.dict.index_to_freq:clone()
unigrams:div(unigrams:sum())


local model = nn.LanguageModel(g_params.model, vocab_size, unigrams)





local function eval(split_id)

	model:evaluate()
	split_id = split_id or 2
	
	local x, y = batch_loader:next_batch(split_id)
	local N, T = x:size(1), x:size(2)
	local total_loss = 0
	local total_samples = 0
	
	--~ note that batch size in eval is different to batch size in training (small)
	model:createHiddenInput(T)
	
	local index = 1
	
	while index <= N do
		
		local stop = math.min(N, index + 16)
		xlua.progress(stop, N)
		local x_seq = x:sub(index, stop, 1, -1)
		local y_seq = y:sub(index, stop, 1, -1)
		
		local loss, n_samples = model:eval(x_seq, y_seq)
		total_loss = total_loss + loss
		total_samples = total_samples + n_samples
		index = index + 17
	end
	

	
	local avg_loss = total_loss / total_samples
	local ppl = torch.exp(avg_loss)

	return avg_loss
end


local function train_epoch(learning_rate, batch_size)
	model:training()
		
	batch_loader:reset_batch_pointer(1)
	model:createHiddenInput(batch_size)
	
	-- if hsm == true then hsm_grad_params:zero() end
	local speed
	local n_batches = batch_loader.split_sizes[1]
	local total_loss = 0
	local total_samples = 0

	local timer = torch.tic()
	
	for i = 1, n_batches do
		
		xlua.progress(i, n_batches)

		-- forward pass 
		local input, target = batch_loader:next_batch(split)
		
		local loss, n_samples = model:trainBatch(input, target, learning_rate)
		--~ model:resetStates()
		total_loss = total_loss + loss
		total_samples = total_samples + n_samples
		
	end

	local elapse = torch.toc(timer)
	

	total_loss = total_loss / total_samples

	local perplexity = torch.exp(total_loss)
	
	collectgarbage()
	
	local speed = math.floor(total_samples * batch_size / elapse)

	return total_loss, speed

end

local function run(n_epochs)

	local val_loss = {}
	local l = eval(2)
	print(torch.exp(l))
	val_loss[0] = l

	local patience = 0

	local learning_rate = g_params.trainer.initial_learning_rate
	local batch_size = g_params.trainer.batch_size
	
	
	for epoch = 1, n_epochs do
		
		-- early stopping when no improvement for a long time
		if patience >= g_params.trainer.max_patience then break end
		
		local train_loss, wps = train_epoch(learning_rate, batch_size)

		
		val_loss[epoch] = eval(2)
	
		
		--~ Control patience when no improvement
		if val_loss[epoch] >= val_loss[epoch - 1] * g_params.trainer.shrink_factor then
			patience = patience + 1
			learning_rate = learning_rate / g_params.trainer.learning_rate_shrink
			model:revertBestParams()
		else
			patience = 0
			model:saveBestParams()
		end
		
		
		--~ Display training information
		local stat = {train_perplexity = torch.exp(train_loss) , epoch = epoch,
                valid_perplexity = torch.exp(val_loss[epoch]), LR = learning_rate, speed = wps, patience = patience}

        print(stat)
        
        -- save the trained model
		--~ local save_dir = g_params.trainer.save_dir
		--~ if save_dir ~= nil then
		  --~ if paths.dirp(save_dir) == false then
			  --~ os.execute('mkdir -p ' .. save_dir)	
		  --~ end
		  --~ local save_state = {}
		  --~ save_state.model = model
		  --~ save_state.criterion = criterion
		  --~ save_state.learning_rate = learning_rate
		  --~ torch.save(paths.concat(save_dir, 'model_' .. epoch), save_state)
		--~ end

        -- early stop when learning rate too small
        if learning_rate <= 1e-4 then break end
        
		

	end

	print(torch.exp(eval(3)))
	
end

run(g_params.trainer.n_epochs)



