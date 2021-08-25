# Copyright (c) 2020 ETH Zurich, University of Bologna
# All rights reserved.
#
# This code is under development and not yet released to the public.
# Until it is released, the code is under the copyright of ETH Zurich and
# the University of Bologna, and may contain confidential and/or unpublished
# work. Any reuse/redistribution is strictly forbidden without written
# permission from ETH Zurich.

# DMA trace 
# experimental code
# this could should not be used by anyone, 
# especially not in production environments

import ast
import sys
import argparse
from dma_backend import *


def burst_req_in (trace_dict):
    # pre-format for printing
    format_list = []
    format_list.append('ID    : {:16d}  '.format(trace_dict['backend_burst_req_id']))
    format_list.append('SRC   : {:16x}  '.format(trace_dict['backend_burst_req_src']))
    format_list.append('DST   : {:16x}  '.format(trace_dict['backend_burst_req_dst']))
    format_list.append('LENGTH: {:16d}  '.format(trace_dict['backend_burst_req_num_bytes']))
    format_list.append('DC    : {:16b}  '.format(trace_dict['backend_burst_req_burst_decouple_rw']))
    format_list.append('DB    : {:16b}  '.format(trace_dict['backend_burst_req_burst_deburst']))
    return {'unit' : 'Backend', 'level': 0, 'event': 'New 1D Request:           ', 'payload': format_list}


def burst_req_process (trace_dict, read_requests, write_requests, reads, writes):
    # read burst req infos
    src = trace_dict['burst_reshaper_burst_req_src']
    dst = trace_dict['burst_reshaper_burst_req_dst']
    num_bytes = trace_dict['burst_reshaper_burst_req_num_bytes']
    decouple = trace_dict['burst_reshaper_burst_req_decouple_rw']
    deburst = trace_dict['burst_reshaper_burst_req_deburst']
    # evoke model
    [new_r_reqs, new_w_reqs, new_reads, new_writes] = dma_backend(src, dst, num_bytes, decouple, deburst)
    # calculate the utilization
    [r_util, w_util] = get_bus_util(new_r_reqs, new_w_reqs, new_reads, new_writes, trace_dict['DataWidth'])
    # append to lists
    read_requests.extend(new_r_reqs)
    write_requests.extend(new_w_reqs)
    reads.extend(new_reads)
    writes.extend(new_writes)
    # pre-format for printing
    format_list = []
    format_list.append('ID    : {:16d}  '.format(trace_dict['burst_reshaper_burst_req_id']))
    format_list.append('SRC   : {:16x}  '.format(src))
    format_list.append('DST   : {:16x}  '.format(dst))
    format_list.append('LENGTH: {:16d}  '.format(num_bytes))
    format_list.append('DC    : {:16b}  '.format(decouple))
    format_list.append('DB    : {:16b}  '.format(deburst))
    return [{'unit' : 'BurstReshaper', 'event': 'New 1D Request:           ', 'payload': format_list}, r_util, w_util]


def transfer_completed(trace_dict, num_outstanding):
    # pre-format for printing
    format_list = []
    format_list.append('TRANSFER LEFT  : {:7d}  '.format(num_outstanding))
    return {'unit' : 'Backend', 'level': 0, 'event': 'Transfer Completed        ', 'payload': format_list}


def read_issued(trace_dict):
    # pre-format for printing
    format_list = []
    strb_width = trace_dict['DataWidth'] // 8
    shift = (strb_width - trace_dict['burst_reshaper_read_req_r_shift']) % strb_width;
    format_list.append('ID    : {:16d}  '.format(trace_dict['burst_reshaper_read_req_ar_id']))
    format_list.append('ADDR  : {:16x}  '.format(trace_dict['burst_reshaper_read_req_ar_addr']))
    format_list.append('LENGTH: {:16d}  '.format(trace_dict['burst_reshaper_read_req_ar_len']))
    format_list.append('OFFSET: {:16d}  '.format(trace_dict['burst_reshaper_read_req_r_offset']))
    format_list.append('TAILER: {:16d}  '.format(trace_dict['burst_reshaper_read_req_r_tailer']))
    format_list.append('SHIFT : {:16d}  '.format(shift))
    format_list.append('LAST  : {:16b}  '.format(trace_dict['burst_reshaper_read_req_ar_last']))
    return {'unit' : 'BurstReshaper', 'level': 0, 'event': 'Read Issued:              ', 'payload': format_list}


def check_read_issued(trace_dict, read_requests):
    # check if request is correct
    try:
        read_request    = read_requests.pop(0)
    except:
        return {'unit' : 'BRModel', 'level': 1, 'event': 'Missing Read Request      ', 'payload': []}
    strb_width = trace_dict['DataWidth'] // 8
    shift = (strb_width - trace_dict['burst_reshaper_read_req_r_shift']) % strb_width;
    addr_correct    = read_request['addr']    == trace_dict['burst_reshaper_read_req_ar_addr']
    size_correct    = read_request['size']    == trace_dict['burst_reshaper_read_req_ar_len']
    offset_correct  = read_request['offset']  == trace_dict['burst_reshaper_read_req_r_offset']
    tailer_correct  = read_request['tailer']  == trace_dict['burst_reshaper_read_req_r_tailer']
    shift_correct   = read_request['shift']   == shift
    error_free = addr_correct and size_correct and offset_correct and tailer_correct and shift_correct
    # error happens
    if not error_free:
        format_list = []
        format_list.append('ID    : {:16d}  '.format(trace_dict['burst_reshaper_read_req_ar_id']))
        format_list.append('ADDR  : {:16x}  '.format(read_request['addr']))
        format_list.append('LENGTH: {:16d}  '.format(read_request['size']))
        format_list.append('OFFSET: {:16d}  '.format(read_request['offset']))
        format_list.append('TAILER: {:16d}  '.format(read_request['tailer']))
        format_list.append('SHIFT : {:16d}  '.format(read_request['shift']))
        format_list.append('LAST  : {:16b}  '.format(trace_dict['burst_reshaper_read_req_ar_last']))
        return {'unit' : 'BRModel', 'level': 1, 'event': 'Read Issued:              ', 'payload': format_list}
    return None


def write_issued(trace_dict):
    # pre-format for printing
    format_list = []
    format_list.append('ID    : {:16d}  '.format(trace_dict['burst_reshaper_write_req_aw_id']))
    format_list.append('ADDR  : {:16x}  '.format(trace_dict['burst_reshaper_write_req_aw_addr']))
    format_list.append('LENGTH: {:16d}  '.format(trace_dict['burst_reshaper_write_req_aw_len']))
    format_list.append('OFFSET: {:16d}  '.format(trace_dict['burst_reshaper_write_req_w_offset']))
    format_list.append('TAILER: {:16d}  '.format(trace_dict['burst_reshaper_write_req_w_tailer']))
    format_list.append('BEATS : {:16d}  '.format(trace_dict['burst_reshaper_write_req_w_num_beats']))
    format_list.append('LAST  : {:16b}  '.format(trace_dict['burst_reshaper_write_req_aw_last']))
    return {'unit' : 'BurstReshaper', 'level': 0, 'event': 'Write Issued:             ', 'payload': format_list}


def check_write_issued(trace_dict, write_requests):
    # check if request is correct
    try:
        write_request    = write_requests.pop(0)
    except:
        return {'unit' : 'BRModel', 'level': 1, 'event': 'Missing Write Request     ', 'payload': []}

    addr_correct     = write_request['addr']    == trace_dict['burst_reshaper_write_req_aw_addr']
    size_correct     = write_request['size']    == trace_dict['burst_reshaper_write_req_aw_len']
    offset_correct   = write_request['offset']  == trace_dict['burst_reshaper_write_req_w_offset']
    tailer_correct   = write_request['tailer']  == trace_dict['burst_reshaper_write_req_w_tailer']
    size_correct     = write_request['size']    == trace_dict['burst_reshaper_write_req_w_num_beats']
    error_free = addr_correct and size_correct and offset_correct and tailer_correct and size_correct
    # error happens
    if not error_free:
        format_list = []
        format_list.append('ID    : {:16d}  '.format(trace_dict['burst_reshaper_write_req_aw_id']))
        format_list.append('ADDR  : {:16x}  '.format(write_request['addr']))
        format_list.append('LENGTH: {:16d}  '.format(write_request['size']))
        format_list.append('OFFSET: {:16d}  '.format(write_request['offset']))
        format_list.append('TAILER: {:16d}  '.format(write_request['tailer']))
        format_list.append('BEATS : {:16d}  '.format(write_request['size']))
        format_list.append('LAST  : {:16b}  '.format(trace_dict['burst_reshaper_write_req_aw_last']))
        return {'unit' : 'BRModel', 'level': 1, 'event': 'Write Issued:             ', 'payload': format_list}
    return None


def read_to_buffer (trace_dict):
    # pre-format for printing
    format_list = []
    format_list.append('RMASK : {:016x}  '.format(trace_dict['data_path_read_aligned_in_mask']))
    format_list.append('WAMASK: {:016x}  '.format(trace_dict['data_path_write_aligned_in_mask']))
    return {'unit' : 'DataPath', 'level': 0, 'event': 'Fill Buffer (READ):       ', 'payload': format_list}


def check_read_to_buffer (trace_dict, reads):
    # check if model can read
    try:
        read = reads.pop(0)
    except:
        return {'unit' : 'DPModel', 'level': 1, 'event': 'Missing Read              ', 'payload': []}

    # check if read is correct
    r_mask_correct  = read['r_mask']  == trace_dict['data_path_read_aligned_in_mask']
    wa_mask_correct = read['wa_mask'] == trace_dict['data_path_write_aligned_in_mask']
    error_free = r_mask_correct and wa_mask_correct
    # error happens
    if not error_free:
        # pre-format for printing
        format_list = []
        format_list.append('RMASK : {:016x}  '.format(read['r_mask']))
        format_list.append('WAMASK: {:016x}  '.format(read['wa_mask']))
        return {'unit' : 'DPModel', 'level': 1, 'event': 'Fill Buffer (READ):       ', 'payload': format_list}
    return None


def write_from_buffer (trace_dict):
    # pre-format for printing
    format_list = []
    format_list.append('WMASK : {:016x}  '.format(trace_dict['axi_dma_bus_w_strb']))
    return {'unit' : 'DataPath', 'level': 0, 'event': 'Pop Buffer (Write):       ', 'payload': format_list}


def check_write_from_buffer (trace_dict, writes):
    # check if model can write
    try:
        write = writes.pop(0)
    except:
        return {'unit' : 'DPModel', 'level': 1, 'event': 'Missing Write             ', 'payload': []}

    # check if write is correct
    w_mask_correct  = write['w_mask']  == trace_dict['axi_dma_bus_w_strb']
    error_free = w_mask_correct 
    # error happens
    if not error_free:
        # pre-format for printing
        format_list = []
        format_list.append('WMASK : {:016x}  '.format(write['w_mask']))
        return {'unit' : 'DPModel', 'level': 1, 'event': 'Pop Buffer (Write):       ', 'payload': format_list}
    return None


def print_frame(time, last_time, period, frame):
    trace_str = ''

    # print line of ≈ to signalize break in time
    if time - last_time > period:
        trace_str += '\n≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈\n'
        trace_str += '\n-----------------------------------------------------------------------------------------------------------------------------------------------------------------\n'

    # display 6 categories in 6 columns: time, backend, burst_reshaper, br_model, data path, dp_model
    # first, find all events for each unit
    time_depth = 1
    time_events = ['{:16d}ns '.format(time)]

    backend_depth  = 0
    backend_events = []
    backend_first = True
    for ele in frame:
        if ele['unit'] == 'Backend':
            backend_depth += len(ele['payload']) + 1
            if not backend_first:
                backend_depth += 1
                backend_events.append('°°°°°°°°°°°°°°°°°°°°°°°°°°')
            backend_events.append(ele['event'])
            backend_first = False
            if ele['payload']:
                backend_events.extend(ele['payload'])

    br_depth  = 0
    br_events = []
    br_first = True
    for ele in frame:
        if ele['unit'] == 'BurstReshaper':
            br_depth += len(ele['payload']) + 1
            if not br_first:
                br_depth += 1
                br_events.append('°°°°°°°°°°°°°°°°°°°°°°°°°°')
            br_events.append(ele['event'])
            br_first = False
            if ele['payload']:
                br_events.extend(ele['payload'])

    br_model_depth  = 0
    br_model_events = []
    br_model_first = True
    for ele in frame:
        if ele['unit'] == 'BRModel':
            br_model_depth += len(ele['payload']) + 1
            if not br_model_first:
                br_model_depth += 1
                br_model_events.append('°°°°°°°°°°°°°°°°°°°°°°°°°°')
            br_model_events.append(ele['event'])
            br_model_first = False
            if ele['payload']:
                br_model_events.extend(ele['payload'])

    dp_depth  = 0
    dp_events = []
    dp_first = True
    for ele in frame:
        if ele['unit'] == 'DataPath':
            dp_depth += len(ele['payload']) + 1
            if not dp_first:
                dp_depth += 1
                dp_events.append('°°°°°°°°°°°°°°°°°°°°°°°°°°')
            dp_events.append(ele['event'])
            dp_first = False
            if ele['payload']:
                dp_events.extend(ele['payload'])

    dp_model_depth  = 0
    dp_model_events = []
    dp_model_first = True
    for ele in frame:
        if ele['unit'] == 'DPModel':
            dp_model_depth += len(ele['payload']) + 1
            if not dp_model_first:
                dp_model_depth += 1
                dp_model_events.append('°°°°°°°°°°°°°°°°°°°°°°°°°°')
            dp_model_events.append(ele['event'])
            dp_model_first = False
            if ele['payload']:
                dp_model_events.extend(ele['payload'])

    total_depth_of_frame = max(time_depth, backend_depth, br_depth, br_model_depth, dp_depth, dp_model_depth)
    # print(total_depth_of_frame)

    # format frame table
    # header
    trace_str += '|              Time '
    trace_str += '| Backend                   '
    trace_str += '| Burst Reshaper            '
    trace_str += '| Burst Reshaper (Model)    '
    trace_str += '| Data Path                 '
    trace_str += '| Data Path (Model)         '
    trace_str += '|\n'
    
    # frame body
    for i in range(0, total_depth_of_frame):
        # time
        try:
            trace_str += '|' + time_events[i]
        except:
            trace_str += '|                   '

        # backend
        try:
            trace_str += '| ' + backend_events[i]
        except:
            trace_str += '|                           '

        # burst reshaper
        try:
            trace_str += '| ' + br_events[i]
        except:
            trace_str += '|                           '

        # burst reshaper model
        try:
            trace_str += '| ' + br_model_events[i]
        except:
            trace_str += '|                           '

        # data path
        try:
            trace_str += '| ' + dp_events[i]
        except:
            trace_str += '|                           '

        # data path model
        try:
            trace_str += '| ' + dp_model_events[i]
        except:
            trace_str += '|                           '

        trace_str += '|\n'
    
    # frame footer
    trace_str += '-----------------------------------------------------------------------------------------------------------------------------------------------------------------\n'
    return trace_str


# helper function: stobe to num_bytes
def strb_to_bytes(strobe):
    res = 0
    for byte_en in str(bin(strobe))[2:]:
        if(byte_en == '1'):
            res += 1
    return res


# update performance metrics
def update_perf_dict(trace_dict, perf_dict, r_util, w_util):
    # we do a cycle anyways
    perf_dict['num_cycles'] += 1

    # active cycles
    if not trace_dict['backend_idle']:
        perf_dict['num_act_cycles'] += 1

    # count AXI bus transfers
    if trace_dict['axi_dma_bus_aw_ready'] and trace_dict['axi_dma_bus_aw_valid']:
        perf_dict['num_aw'] += 1
        perf_dict['aw_bytes_req'] += (trace_dict['axi_dma_bus_aw_len'] + 1) << trace_dict['axi_dma_bus_aw_size']

    if trace_dict['axi_dma_bus_ar_ready'] and trace_dict['axi_dma_bus_ar_valid']:
        perf_dict['num_ar'] += 1
        perf_dict['ar_bytes_req'] += (trace_dict['axi_dma_bus_ar_len'] + 1) << trace_dict['axi_dma_bus_ar_size']

    if trace_dict['axi_dma_bus_w_ready'] and trace_dict['axi_dma_bus_w_valid']:
        perf_dict['num_w'] += 1
        perf_dict['bytes_written'] += strb_to_bytes(trace_dict['axi_dma_bus_w_strb'])

    if trace_dict['axi_dma_bus_r_ready'] and trace_dict['axi_dma_bus_r_valid']:
        perf_dict['num_r'] += 1
        perf_dict['bytes_read'] += trace_dict['DataWidth'] // 8

    if trace_dict['axi_dma_bus_b_ready'] and trace_dict['axi_dma_bus_b_valid']:
        perf_dict['num_b'] += 1

    # stall information
    if not trace_dict['backend_idle'] and trace_dict['axi_dma_bus_r_ready'] and not trace_dict['axi_dma_bus_r_valid']:
        perf_dict['wait_for_read'] += 1

    if not trace_dict['backend_idle'] and trace_dict['axi_dma_bus_w_valid'] and not trace_dict['axi_dma_bus_w_ready']:
        perf_dict['wait_for_write'] += 1

    if not trace_dict['backend_idle'] and trace_dict['axi_dma_bus_w_ready'] and trace_dict['axi_dma_bus_r_valid']:
        if not trace_dict['axi_dma_bus_w_valid'] or not trace_dict['axi_dma_bus_r_ready']:
            perf_dict['stall_internal'] += 1

    # utilization information
    if trace_dict['backend_burst_req_valid'] and trace_dict['backend_burst_req_ready']:
        length = trace_dict['backend_burst_req_num_bytes'];        
        perf_dict['min_len'] = min(length, perf_dict['min_len'])
        perf_dict['tot_len'] += length
        perf_dict['max_len'] = max(length, perf_dict['max_len'])
        perf_dict['num_transfers'] += 1

    if trace_dict['burst_reshaper_burst_req_valid'] and trace_dict['burst_reshaper_burst_req_ready']:        
        perf_dict['min_r_util'] = min(perf_dict['min_r_util'], r_util)
        perf_dict['max_r_util'] = max(perf_dict['max_r_util'], r_util)
        perf_dict['tot_r_util'] += r_util
        perf_dict['min_w_util'] = min(perf_dict['min_w_util'], w_util)
        perf_dict['max_w_util'] = max(perf_dict['max_w_util'], w_util)
        perf_dict['tot_w_util'] += w_util


def safe_divide(n, d):
    return n / d if d else 0


# print performance statistics
def print_perf_stats(perf_dict, period):
    res = '\n\nPerformance Statistic\n---------------------\n\n'

    # print stats
    res += 'Number of cycles Traced:   {:7d}\n'.format(perf_dict['num_cycles'])
    res += 'Number of cycles Active:   {:7d}\n'.format(perf_dict['num_act_cycles'])
    res += 'Average Activity:          {:10.2f}%\n'.format(perf_dict['num_act_cycles'] / perf_dict['num_cycles'] * 100)
    res += 'Number of Transfers:       {:7d}\n'.format(perf_dict['num_transfers'])
    res += '\n'

    res += 'Minimal Transfer Length:   {:7d} Bytes\n'.format(perf_dict['min_len'])
    res += 'Average Transfer Length:   {:7d} Bytes\n'.format(int(safe_divide(perf_dict['tot_len'], perf_dict['num_transfers'])))
    res += 'Maximum Transfer Length:   {:7d} Bytes\n'.format(perf_dict['max_len'])
    res += '\n'    

    res += 'Data Read:                 {:12.4f} kiB\n'.format(perf_dict['ar_bytes_req'] / (1024))
    res += 'Data Written (Bus):        {:12.4f} kiB\n'.format(perf_dict['aw_bytes_req'] / (1024))
    res += 'Data Written:              {:12.4f} kiB\n'.format(perf_dict['bytes_written'] / (1024))
    res += 'Bus Utilization:           {:12.4f}%\n'.format(safe_divide(perf_dict['bytes_written'], perf_dict['ar_bytes_req']) * 100)
    res += 'Overall Bus Utilization:   {:12.4f}%\n'.format(safe_divide(perf_dict['bytes_written'], perf_dict['ar_bytes_req']) * 100 * 
                                                           perf_dict['num_act_cycles'] / perf_dict['num_cycles'])
    res += '\n'

    res += 'Minimal Read Utilization:  {:12.4f}%\n'.format(perf_dict['min_r_util'] * 100.0)
    res += 'Average Read Utilization:  {:12.4f}%\n'.format(safe_divide(perf_dict['tot_r_util'], perf_dict['num_transfers']) * 100.0)
    res += 'Maximum Read Utilization:  {:12.4f}%\n'.format(perf_dict['max_r_util'] * 100.0)
    res += '\n'  

    res += 'Minimal Write Utilization: {:12.4f}%\n'.format(perf_dict['min_w_util'] * 100.0)
    res += 'Average Write Utilization: {:12.4f}%\n'.format(safe_divide(perf_dict['tot_w_util'], perf_dict['num_transfers']) * 100.0)
    res += 'Maximum Write Utilization: {:12.4f}%\n'.format(perf_dict['max_w_util'] * 100.0)
    res += '\n'  

    run_time     = period / 1000000000 * perf_dict['num_cycles']
    freqency_mhz = 1.0 / period * 1000
    active_time  = run_time * safe_divide(perf_dict['num_act_cycles'], perf_dict['num_cycles'])

    res += 'Average Read Speed:        {:12.4f} MiB/s @ {:.2f} MHz\n'.format(perf_dict['ar_bytes_req']  / (1024 * 1024) / run_time, freqency_mhz)
    res += 'Average Write Speed (Bus): {:12.4f} MiB/s @ {:.2f} MHz\n'.format(perf_dict['aw_bytes_req']  / (1024 * 1024) / run_time, freqency_mhz)
    res += 'Average Write Speed:       {:12.4f} MiB/s @ {:.2f} MHz\n'.format(perf_dict['bytes_written'] / (1024 * 1024) / run_time, freqency_mhz)
    res += '\n'
 
    res += 'Active Read Speed:         {:12.4f} MiB/s @ {:.2f} MHz\n'.format(safe_divide(perf_dict['ar_bytes_req'], active_time) / (1024 * 1024), freqency_mhz)
    res += 'Active Write Speed (Bus):  {:12.4f} MiB/s @ {:.2f} MHz\n'.format(safe_divide(perf_dict['aw_bytes_req'], active_time) / (1024 * 1024), freqency_mhz)
    res += 'Active Write Speed:        {:12.4f} MiB/s @ {:.2f} MHz\n'.format(safe_divide(perf_dict['bytes_written'], active_time) / (1024 * 1024), freqency_mhz)
    res += '\n'

    res += 'Wait for Read:             {:12.4f}%\n'.format(safe_divide(perf_dict['wait_for_read'], perf_dict['num_act_cycles']) * 100.0)
    res += 'Wait for Write:            {:12.4f}%\n'.format(safe_divide(perf_dict['wait_for_write'], perf_dict['num_act_cycles']) * 100.0)
    res += 'Internal Stall:            {:12.4f}%\n'.format(safe_divide(perf_dict['stall_internal'], perf_dict['num_act_cycles']) * 100.0)



    return res + '\n'


def get_bus_util(new_r_reqs, new_w_reqs, new_reads, new_writes, bus_width):

    # calculate number of beats
    num_r_beats = 0
    num_w_beats = 0
    for r_req in new_r_reqs:
        num_r_beats += r_req['size'] + 1
    for w_req in new_w_reqs:
        num_w_beats += w_req['size'] + 1

    # calculate number of valid bytes on bus
    num_r_bytes = 0
    num_w_bytes = 0
    for read in new_reads:
        num_r_bytes += strb_to_bytes(read['r_mask'])
    for write in new_writes:
        num_w_bytes += strb_to_bytes(write['w_mask'])

    r_util = safe_divide(num_r_bytes, num_r_beats * bus_width // 8)
    w_util = safe_divide(num_w_bytes, num_w_beats * bus_width // 8)

    return [r_util, w_util]


# do the dma tracing
def trace_file (filename, stop_on_error = True, silent = False):

    # the model divides transfers in "instructions". everything is in-order
    # keep lists of these instructions
    read_requests = []
    write_requests = []
    reads = []
    writes = []

    # number of outstanding transfers
    num_outstanding = 0

    # create an empty perf dict:
    perf_dict = { 'num_cycles'    : 0, 
                  'num_act_cycles': 0,
                  'num_aw'        : 0,
                  'num_ar'        : 0,
                  'num_w'         : 0,
                  'num_r'         : 0,
                  'num_b'         : 0,
                  'aw_bytes_req'  : 0,
                  'ar_bytes_req'  : 0,
                  'bytes_read'    : 0,
                  'bytes_written' : 0,
                  'wait_for_read' : 0,
                  'wait_for_write': 0,
                  'stall_internal': 0,
                  'min_len'       : sys.maxsize,
                  'tot_len'       : 0,
                  'max_len'       : 0,
                  'num_transfers' : 0,
                  'min_r_util'    : sys.maxsize,
                  'max_r_util'    : 0,
                  'tot_r_util'    : 0,
                  'min_w_util'    : sys.maxsize,
                  'max_w_util'    : 0,
                  'tot_w_util'    : 0,
                }

    # iterate over file
    with open(filename, 'r') as trace_file:
        last_time = -1
        # used to learn clock period
        first = True
        second = False
        period = 0
        r_util = 0
        w_util = 0
        for line in trace_file:
            # each line is a dict
            try:
                trace_dict = ast.literal_eval(line)
            except:
                continue

            # frame is constructed for printing trace
            frame = []
            error = False
            time = trace_dict['time']

            # learn clock period
            if second:
                second = False
                period = time - period
                #print("Detected Clock period of {}ns".format(period))
            if first:
                first = False
                second = True
                period = time

            # reject inactive cycles
            if 'backend_idle' not in trace_dict:
                continue

            # new burst request arrives
            if trace_dict['backend_burst_req_valid'] and trace_dict['backend_burst_req_ready']:
                frame.append(burst_req_in(trace_dict))
                num_outstanding += 1


            # new burst request enters burst reshaper
            if trace_dict['burst_reshaper_burst_req_valid'] and trace_dict['burst_reshaper_burst_req_ready']:
                [req, r_util, w_util] = burst_req_process(trace_dict, read_requests, write_requests, reads, writes)
                frame.append(req)

            # transfer retired
            if trace_dict['transfer_completed']:
                num_outstanding -= 1
                frame.append(transfer_completed(trace_dict, num_outstanding))
               

            # check read request issued
            if trace_dict['burst_reshaper_read_req_valid'] and trace_dict['burst_reshaper_read_req_ready']:
                frame.append(read_issued(trace_dict))
                check = check_read_issued(trace_dict, read_requests)
                if check:
                    frame.append(check)
                    error = True

            # check write request issued
            if trace_dict['burst_reshaper_write_req_valid'] and trace_dict['burst_reshaper_write_req_ready']:
                frame.append(write_issued(trace_dict))
                check = check_write_issued(trace_dict, write_requests)
                if check:
                    frame.append(check)
                    error = True

            # check if correct data is placed in buffer
            if trace_dict['data_path_push']:
                frame.append(read_to_buffer(trace_dict))
                check = check_read_to_buffer(trace_dict, reads)
                if check:
                    frame.append(check)
                    error = True

            # check if correct data is read from buffer
            if trace_dict['data_path_pop']:
                frame.append(write_from_buffer(trace_dict))
                check = check_write_from_buffer(trace_dict, writes)
                if check:
                    frame.append(check)
                    error = True

            # print frame (if something has happened)
            if len(frame) > 0 and not silent:
                print(print_frame(time, last_time, period, frame), end='')
                last_time = time

            # update perf_dict
            update_perf_dict(trace_dict, perf_dict, r_util, w_util)

            # stop trace at first error
            if error and stop_on_error:
                print('\nModel and RTL mismatch @ {}ns - I give up; stopping trace!\n'.format(time))
                break

    # finally print perf statistics
    print(print_perf_stats(perf_dict, period))


# argparser
parser = argparse.ArgumentParser(description='Read DMA trace files, display the DMA trace and \
                                 and display performance statistics.')
parser.add_argument('dma_trace_log', metavar='dma_trace_log', type=str,
                    help='the raw log file emitted by the backend.')
parser.add_argument('--silent', dest='silent', action='store_true',
                    help='only print statistics')
parser.add_argument('--continue-on-error', dest='coe', action='store_true',
                    help='continue tracing when encountering error')
args = parser.parse_args()

# run the main
trace_file(args.dma_trace_log, stop_on_error = not args.coe, silent = args.silent)
