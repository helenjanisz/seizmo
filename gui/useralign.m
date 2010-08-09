function [info,xc,data0]=useralign(data,varargin)
%USERALIGN    Interactive alignment of a signal for SEIZMO records
%
%    Usage:    [info,xc,data0]=useralign(data)
%              [...]=useralign(data,'option1',value1,...,'optionN',valueN)
%
%    Description: [INFO,XC,DATA0]=USERALIGN(DATA) presents an interactive
%     set of menus & plots to guide the aligning of records in SEIZMO
%     struct DATA on a particular signal.  The workflow includes
%     interactively applying a moveout, windowing, tapering, adjusting
%     correlation options.  Once the solving is complete the user is
%     allowed to pick the onset of the stack to get the arrival times as
%     close as possible to "picked" times.  Afterwards, a plot presents the
%     results and a menu asks the user to decide to accept those results,
%     redo the processing, or exit with an error (to break any chance of
%     doing subsequent processing).  INFO is a struct containing several
%     substructs providing details for the options used in each subfunction
%     (USERMOVEOUT, USERWINDOW, USERTAPER, CORRELATE, TTSOLVE) as well as
%     the final solution within INFO.SOLUTION.  XC is the struct from
%     CORRELATE reordered by TTSOLVE (contains the correlogram peaks used
%     to find the solution).  DATA0 is the processed dataset (windowed,
%     tapered & aligned).
%
%     [...]=USERALIGN(DATA,'OPTION1',VALUE1,...,'OPTIONN',VALUEN) passes
%     options to CORRELATE & TTSOLVE for enhanced control of the workflow.
%     Currently available options are all options in TTSOLVE and 3 options
%     in CORRELATE: 'NPEAKS', 'SPACING', & 'ABSXC'.  See those functions
%     for details about the options.  Note that NPEAKS must be >=1!
%
%    Notes:
%
%    Examples:
%     Say we have some recordings of a large teleseismic earthquake and
%     that we have inserted the expected arrival times of Pdiff into the
%     headers of these records.  Were did we get those expected arrival
%     times?  The TauP routine TAUPTIME is used to raytrace through a 1D
%     model such as PREM to get them (ADDARRIVALS is probably the easiest
%     method as it will call TAUPTIME and automatically add the arrival
%     times to the header).  The first step is to "pre-align" on those
%     times so that we can attempt to isolate the Pdiff waveforms from
%     other seismic phases using windowing and tapering.  The Pdiff
%     waveforms will have noticeable perturbations from this alignment
%     because the 1D model does not account for the Earth's lateral
%     heterogeniety in seismic properties.  To enhance this initial
%     alignment, we can either go through and pick each signal onset
%     manually (yuck!) or we can use waveform cross-correlation to solve
%     for the best relative arrival times between all the recorded signals
%     (there are certainly other ways to align seismic phases but for now
%     let's focus on the later method mentioned here).  USERALIGN provides
%     us with an interface to do the later method.  It includes a set of
%     menus and plots to aid us in both the signal isolation and alignment
%     enhancing by solving for time perturbations utilizing multi-channel
%     cross-correlation.  Great!  So this is pretty easy: pre-align using
%     an initial guess such as expected arrivals from a 1D Earth model,
%     isolate the signal using windowing and tapering, and finally
%     realigning using cross-correlation:
%      data=timeshift(data,-getarrival(data,'Pdiff'));
%      [info,xc,data0]=useralign(data);
%
%     I usually like to get a SNR estimate of the waveforms to help the
%     cross-correlation solution decide which waveforms are more reliable:
%      data=timeshift(data,-getarrival(data,'Pdiff'));
%      snr=quicksnr(data,[-100 -10],[-10 60]);
%      [info,xc,data0]=useralign(data,'snr',snr);
%
%    See also: TTSOLVE, CORRELATE, USERWINDOW, USERTAPER, USERRAISE,
%              USERMOVEOUT, USERCLUSTEREDALIGN, MULTIBANDALIGN

%     Version History:
%        Mar. 16, 2010 - initial version (not really but whatever)
%        Mar. 17, 2010 - add xc, data0 to output, more crash options
%        Mar. 18, 2010 - output reordered xc (new TTSOLVE output), robust
%                        to menu closing
%        Mar. 22, 2010 - account for TTALIGN change, increase NPEAKS to 5
%        Mar. 24, 2010 - include stack picking to deal with dc-offset,
%                        user-driven cluster analysis for more info
%        Mar. 26, 2010 - drop cluster analysis (can be done separately),
%                        changed output (moved into info.solution)
%        Apr. 22, 2010 - replace crash with exit (but still crash)
%        Aug.  8, 2010 - doc update and slight code adjustments
%
%     Written by Garrett Euler (ggeuler at wustl dot edu)
%     Last Updated Aug.  8, 2010 at 11:00 GMT

% todo:
% - Honestly I would prefer this to be a single gui with a tabbed interface
%   but I don't have any experience with making them yet.

% check nargin
error(nargchk(1,inf,nargin));

% check data (dep)
versioninfo(data,'dep');

% turn off struct checking
oldseizmocheckstate=seizmocheck_state(false);

% attempt header check
try
    % check headers
    data=checkheader(data);
    
    % turn off header checking
    oldcheckheaderstate=checkheader_state(false);
catch
    % toggle checking back
    seizmocheck_state(oldseizmocheckstate);
    
    % rethrow error
    error(lasterror)
end

% attempt align
try
    % basic checks on optional inputs
    if(mod(nargin-1,2))
        error('seizmo:useralign:badInput',...
            'Unpaired OPTION/VALUE!');
    elseif(~iscellstr(varargin(1:2:end)))
        error('seizmo:useralign:badInput',...
            'All OPTIONs must be specified with a string!');
    end
    
    % default correlate options
    info.correlate.npeaks=5;
    info.correlate.spacing=10;
    info.correlate.absxc=true;
    
    % parse out the correlate options
    keep=true(nargin-1,1);
    for i=1:2:nargin-1
        switch lower(varargin{i})
            case 'npeaks'
                if(~isscalar(varargin{i+1}) || ~isreal(varargin{i+1}) ...
                        || varargin{i+1}~=fix(varargin{i+1}) ...
                        || varargin{i+1}<1)
                    error('seizmo:useralign:badInput',...
                        'NPEAKS must be an integer >=1 !');
                end
                info.correlate.npeaks=varargin{i+1};
                keep(i:i+1)=false;
            case 'spacing'
                if(~isscalar(varargin{i+1}) || ~isreal(varargin{i+1}) ...
                        || varargin{i+1}<0)
                    error('seizmo:useralign:badInput',...
                        'SPACING must be a positive real (in seconds)!');
                end
                info.correlate.spacing=varargin{i+1};
                keep(i:i+1)=false;
            case 'absxc'
                if(~isscalar(varargin{i+1}) || ~islogical(varargin{i+1}))
                    error('seizmo:useralign:badInput',...
                        'ABSXC must be a logical value!');
                end
                info.correlate.absxc=varargin{i+1};
                keep(i:i+1)=false;
        end
    end
    varargin=varargin(keep);
    
    % require the o field is set to the same value (within +/- 2 millisec)
    % - this essentially requires the recordings to be of a single quake
    o=getheader(data,'o');
    outc=cell2mat(getheader(data,'o utc'));
    if(any(abs(timediff(outc(1,:),outc))>0.002))
        error('seizmo:useralign:oFieldVaries',...
            'O field must correspond to one UTC time for all records!');
    end
    
    % copy data to working dataset (so user can go back)
    data0=data;
    
    % outer loop - only breaks free on user command
    happy_user=false; info.iteration=1;
    while(~happy_user)
        % usermoveout
        [data0,info.usermoveout,info.figurehandles(1)]=usermoveout(data0);

        % userwindow
        [data0,info.userwindow,info.figurehandles(2:3)]=userwindow(data0);

        % usertaper
        [data0,info.usertaper,info.figurehandles(4:5)]=usertaper(data0);

        % menu for correlate options
        while(1)
            % present current settings
            tmp1=num2str(info.correlate.npeaks);
            tmp2=num2str(info.correlate.spacing);
            tmp3='YES'; if(info.correlate.absxc); tmp3='NO'; end
            choice=menu('CORRELATE SETTINGS',...
                'GO AHEAD AND CORRELATE DATA',...
                ['NUMBER OF PEAKS (' tmp1 ')'],...
                ['PEAK SPACING (' tmp2 's)'],...
                ['ARE POLARITIES ARE MATCHED? (' tmp3 ')'],...
                'EXIT WITH AN ERROR');

            % proceed by user choice
            switch choice
                case 1 % all good
                    break;
                case 2 % npeaks
                    choice=menu('NUMBER OF PEAKS TO PICK',...
                        ['CURRENT (' tmp1 ')'],...
                        '1','3','5','7','9','CUSTOM');
                    switch choice
                        case 1 % CURRENT
                            % leave alone
                        case 2 % 1
                            info.correlate.npeaks=1;
                        case 3 % 3
                            info.correlate.npeaks=3;
                        case 4 % 5
                            info.correlate.npeaks=5;
                        case 5 % 7
                            info.correlate.npeaks=7;
                        case 6 % 9
                            info.correlate.npeaks=9;
                        case 7 % CUSTOM
                            tmp=inputdlg(...
                                ['Number of Peaks to Pick? [' tmp1 ']:'],...
                                'Custom Number of Peaks',1,{tmp1});
                            if(~isempty(tmp))
                                try
                                    tmp=str2double(tmp{:});
                                    if(isscalar(tmp) && isreal(tmp) ...
                                            && tmp==fix(tmp) && tmp>=1)
                                        info.correlate.npeaks=tmp;
                                    end
                                catch
                                    % do not change info.correlate.npeaks
                                end
                            end
                    end
                case 3 % spacing
                    tmp=inputdlg(...
                        ['Minimum Spacing Between Peaks (in seconds)? [' ...
                        tmp2 ']:'],'Peak Spacing',1,{tmp2});
                    if(~isempty(tmp))
                        try
                            tmp=str2double(tmp{:});
                            if(isscalar(tmp) && isreal(tmp) && tmp>=0)
                                info.correlate.spacing=tmp;
                            end
                        catch
                            % do not change info.correlate.spacing
                        end
                    end
                case 4 % absxc
                    choice=menu('DO THE POLARITIES ALL MATCH?',...
                        ['CURRENT (' tmp3 ')'],'YES','NO');
                    switch choice
                        case 1 % CURRENT
                            % leave alone
                        case 2 % looking at just positive peaks
                            info.correlate.absxc=false;
                        case 3 % looking at both pos/neg peaks
                            info.correlate.absxc=true;
                    end
                case 5  % i bear too great a shame to go on
                    error('seizmo:usertaper:killYourSelf',...
                        'User demanded early exit!');
            end
        end

        % correlate
        xc=correlate(data0,...
            'npeaks',info.correlate.npeaks,...
            'spacing',info.correlate.spacing,...
            'absxc',info.correlate.absxc);

        % solve alignment
        [arr,err,pol,zmean,zstd,nc,info.ttsolve,xc]=ttsolve(xc,...
            varargin{:});
        
        % align records
        data0=multiply(timeshift(data0,-arr),pol);
        
        % allow picking the stack to deal with dc-shift from onset
        [b,e,delta]=getheader(data0,'b','e','delta');
        [onset,info.figurehandles(6)]=pickstack(normalize(data0),...
            2/min(delta),[],min(b),max(e),0);

        % plot alignment
        data0=timeshift(data0,-onset);
        info.figurehandles(7)=recordsection(data0);
        
        % origin time gives absolute time position
        arr=-getheader(data0,'o');
        
        % force user to decide
        choice=0;
        while(~choice)
            % ask user if they are happy with alignment
            choice=menu('KEEP THIS ALIGNMENT?',...
                'YES',...
                'NO - TRY AGAIN',...
                'NO - TRY AGAIN WITH THESE OFFSETS',...
                'EXIT WITH ERROR');
            switch choice
                case 1 % rainbow's end
                    happy_user=true;
                case 2 % never never quit!
                    data0=data;
                    close(info.figurehandles(...
                        ishandle(info.figurehandles)));
                case 3 % standing on the shoulders of those before me
                    info.iteration=info.iteration+1;
                    data0=timeshift(data,-o-arr);
                    close(info.figurehandles(...
                        ishandle(info.figurehandles)));
                case 4 % i bear too great a shame to go on
                    error('seizmo:useralign:killYourSelf',...
                        'User demanded early exit!');
            end
        end
    end
    
    % put results in info
    info.solution.arr=arr;
    info.solution.arrerr=err;
    info.solution.pol=pol;
    info.solution.zmean=zmean;
    info.solution.zstd=zstd;
    info.solution.nc=nc;
    
    % toggle checking back
    seizmocheck_state(oldseizmocheckstate);
    checkheader_state(oldcheckheaderstate);
catch
    % toggle checking back
    seizmocheck_state(oldseizmocheckstate);
    checkheader_state(oldcheckheaderstate);
    
    % rethrow error
    error(lasterror)
end

end
