# Copyright 2015 Jeff Vierstra

# cython: boundscheck=False
# cython: wraparound=False
# cython: nonecheck=False

cimport numpy as np

import numpy as np

cdef extern from "predict.h":
	struct result:
		double* exp
		double* win	
	void free_result_t(result*)
	result* fast_predict(double*, double*, int, int, int, double)

ctypedef np.float64_t data_type_t

cdef predict(data_type_t [:] obs, data_type_t [:] probs, int half_window_width, int smoothing_half_window_width, double smoothing_clip):

	cdef int i
	cdef int l = obs.shape[0]

	# Predict
	cdef result* res = fast_predict(&obs[0], &probs[0], l, half_window_width, smoothing_half_window_width, smoothing_clip)

	# Copy back into a python object
	cdef np.ndarray[data_type_t, ndim = 1, mode = 'c'] exp = np.zeros(l, dtype = np.float64, order = 'c')
	cdef data_type_t [:] exp_view = exp

	cdef np.ndarray[data_type_t, ndim = 1, mode = 'c'] win = np.zeros(l, dtype = np.float64, order = 'c')
	cdef data_type_t [:] win_view = win

	for i in range(l): 
		exp_view[i] = res.exp[i]
		win_view[i] = res.win[i]

	# Free up the memory from C
	free_result_t(res)

	return exp, win

def reverse_complement(seq):
	"""
	Computes the reverse complement of a genomic sequence
	
	Parameters
	----------
	seq : string 
		FASTA DNA sequence
	
	Returns
	-------
	value: string
		Reverse complement of input sequence
	"""

	compl = { 'A': 'T', 'C': 'G', 'G': 'C', 'T': 'A', 'N': 'N', 'a': 't', 'c': 'g', 'g': 'c', 't': 'a', 'n': 'n'}
	return ''.join([ compl[base] for base in seq ])[::-1]

class prediction(object):

	def __init__(self, reads, fasta, interval, bm, half_window_width = 5, smoothing_half_window_width = 0, smoothing_clip = 0.0):
		
		self.bm = bm
		self.half_window_width = half_window_width
		self.smoothing_half_window_width = smoothing_half_window_width
		self.smoothing_clip = smoothing_clip

		self.padding = self.half_window_width + smoothing_half_window_width

		self.interval = interval

		pad_interval = interval.widen(self.padding)
		
		# Note: We clip the first base when recombining the positive 
		# and negative strand, so add an extra base upfront
		pad_interval.start -= 1

		self.counts = reads[pad_interval]
		self.seq = fasta[pad_interval.chrom][pad_interval.start-bm.offset():pad_interval.end+bm.offset()].seq.upper()

	def compute(self):

		obs_counts = {'+': None, '-': None}
		exp_counts = {'+': None, '-': None}
		win_counts = {'+': None, '-': None}

		for strand in ['+', '-']:

			# Pre-calculate the sequence bias propensity table from bias model
			if strand == '+':
				probs = self.bm.probs(self.seq)
			else:
				probs = self.bm.probs(reverse_complement(self.seq))[::-1]

			exp, win = predict(np.ascontiguousarray(self.counts[strand]), np.ascontiguousarray(probs), self.half_window_width, self.smoothing_half_window_width, self.smoothing_clip)

			w = self.counts[strand].shape[0] - self.padding

			obs_counts[strand] = self.counts[strand][self.padding:w]
			exp_counts[strand] = exp[self.padding:w]
			win_counts[strand] = win[self.padding:w]

		return (obs_counts, exp_counts, win_counts)

