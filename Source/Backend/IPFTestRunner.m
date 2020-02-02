#import "IPFTestRunner.h"
#import "IPFTestRunnerConfiguration.h"

#import "iperf_api.h"
#import "iperf.h"
#import "queue.h"

static __unsafe_unretained IPFTestRunner *s_currentTestRunner;

@interface IPFTestRunner ()

- (void)handleStatsCallback:(struct iperf_test *)test;

@end

static IPFTestRunnerStatus IPFTestRunnerStatusWithErrorState(IPFTestRunnerStatus status, IPFTestRunnerErrorState errorState)
{
  status.errorState = errorState;

  return status;
}

static IPFTestRunnerErrorState IPFTestRunnerErrorStateFromIPerfError(int error)
{
  switch (error) {
    case IENONE:
      return IPFTestRunnerErrorStateNoError;

    case IECONNECT:
      return IPFTestRunnerErrorStateCannotConnectToTheServer;

    case IEACCESSDENIED:
      return IPFTestRunnerErrorStateServerIsBusy;

    default:
      return IPFTestRunnerErrorStateUnknown + error;
  }
}

static void vc_reporter_callback(struct iperf_test *test)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [s_currentTestRunner handleStatsCallback:test];
  });
}

@implementation IPFTestRunner {
  IPFTestRunnerCallback _callback;
  struct iperf_test *_test;
}

- (id)initWithConfiguration:(IPFTestRunnerConfiguration *)configuration
{
  self = [super init];

  if (self) {
    _configuration = configuration;
  }

  return self;
}

- (void)dealloc
{
  NSAssert(s_currentTestRunner == nil && _callback == nil, @"Test should not be running");
}

- (void)startTest:(IPFTestRunnerCallback)callback
{
  IPFTestRunnerConfiguration *configuration = _configuration;
  IPFTestRunnerStatus status;
  struct iperf_test *test = iperf_new_test();
  NSString *streamFilePathTemplate = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iperf3.XXXXXX"];
  __unsafe_unretained IPFTestRunner *blockSelf = self;

  NSAssert([[NSThread currentThread] isMainThread], @"Tests need to run on the main thread");
  status.bandwidth = 0.0;
  status.running = NO;
  status.progress = 0.0;
  status.errorState = IPFTestRunnerErrorStateNoError;

  if (!test) {
    callback(IPFTestRunnerStatusWithErrorState(status, IPFTestRunnerErrorStateCouldntInitializeTest));
    return;
  }

  if (iperf_defaults(test) < 0) {
    callback(IPFTestRunnerStatusWithErrorState(status, IPFTestRunnerErrorStateCouldntInitializeTest));
    return;
  }

  if (configuration.type == IPFTestRunnerConfigurationTypeServer) {
    iperf_set_test_role(test, 's');
  } else {
    iperf_set_test_role(test, 'c');
    iperf_set_test_num_streams(test, (int)configuration.streams);
    set_protocol(test, Pudp); // test default udp protocol

    if (configuration.type == IPFTestRunnerConfigurationTypeDownload) {
      iperf_set_test_reverse(test, 1);
    }
  }

  iperf_set_test_server_hostname(test, (char *)[configuration.hostname cStringUsingEncoding:NSASCIIStringEncoding]);
  iperf_set_test_server_port(test, (int)configuration.port);
  iperf_set_test_duration(test, (int)configuration.duration);

  iperf_set_test_template(test, (char *)[streamFilePathTemplate cStringUsingEncoding:NSUTF8StringEncoding]);
  test->settings->connect_timeout = 3000;
  i_errno = IENONE;

  test->reporter_callback = vc_reporter_callback;
  _test = test;
  NSAssert(s_currentTestRunner == nil, @"Test is already running");
  s_currentTestRunner = self;
  NSAssert(_callback == nil, @"Test is already running");
  _callback = callback;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    if (configuration.type == IPFTestRunnerConfigurationTypeServer) {
      iperf_run_server(test);
    } else {
      iperf_run_client(test);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      IPFTestRunnerStatus callbackStatus = status;
      IPFTestRunnerCallback callback = blockSelf->_callback;

      s_currentTestRunner = nil;
      blockSelf->_callback = nil;
      blockSelf->_test = NULL;
      callbackStatus.running = NO;
      callbackStatus.progress = 1.0;
      callbackStatus.errorState = IPFTestRunnerErrorStateFromIPerfError(i_errno);
      iperf_free_test(test);
      callback(callbackStatus);
    });
  });
}

- (void)stopTest
{
  if (_test != NULL) {
    _test->done = 1;
  }
}

- (void)handleStatsCallback:(struct iperf_test *)test
{
  IPFTestRunnerStatus status;

  status.errorState = IPFTestRunnerErrorStateNoError;
  status.running = YES;

  // See iperf_reporter_callback
  {
    extern double timeval_diff(struct timeval * tv0, struct timeval * tv1);

    struct iperf_stream *stream = NULL;
    struct iperf_interval_results *interval_results = NULL;
    iperf_size_t bytes = 0;
    double bandwidth = 0.0;
    int retransmits = 0;
    int total_packets = 0, lost_packets = 0;
    double avg_jitter = 0.0, lost_percent = 0.0;

    SLIST_FOREACH(stream, &test->streams, streams) {
      interval_results = TAILQ_LAST(&stream->result->interval_results, irlisthead);
      bytes += interval_results->bytes_transferred;

      if (test->protocol->id == Ptcp) {
        if (test->mode == SENDER && test->sender_has_retransmits) {
          retransmits += interval_results->interval_retrans;
        }
      } else {
        total_packets += interval_results->interval_packet_count;
        lost_packets += interval_results->interval_cnt_error;
        avg_jitter += interval_results->jitter;
      }
    }

    stream = SLIST_FIRST(&test->streams);

    if (stream) {
      interval_results = TAILQ_LAST(&stream->result->interval_results, irlisthead);
      bandwidth = (double)bytes / (double)interval_results->interval_duration;
      avg_jitter /= test->num_streams;

      if (total_packets > 0) {
        lost_percent = 100.0 * lost_packets / total_packets;
      } else {
        lost_percent = 0.0;
      }

      //      NSLog(@"Bandwidth on %d streams: %.2f Mbits/s (retransmits: %d, lost: %.2f%%, jitter: %.0f, interval: %.2fs)", test->num_streams, bandwidth * 8 / 1000000, retransmits, lost_percent, avg_jitter * 1000.0, interval_results->interval_duration);
      status.bandwidth = bandwidth * 8 / 1000000;

      if (test->timer) {
        CGFloat test_duration = (CGFloat)test->timer->usecs / 1000000;
        CGFloat test_elapsed = 0.0;

        test_elapsed = test_duration - (test->timer->time.secs - test->stats_timer->time.secs);
        status.progress = test_elapsed / test_duration;
      } else {
        status.progress = 1.0;
      }

      NSAssert([[NSThread currentThread] isMainThread], @"Tests need to run on the main thread");
      _callback(status);
    }
  }
}

@end
