//  Orca
//  ORFlashCamReadoutModel.m
//
//  Created by Tom Caldwell on Monday Dec 26,2019
//  Copyright (c) 2019 University of North Carolina. All rights reserved.
//-----------------------------------------------------------
//This program was prepared for the Regents of the University of
//North Carolina Department of Physics and Astrophysics
//sponsored in part by the United States
//Department of Energy (DOE) under Grant #DE-FG02-97ER41020.
//The University has certain rights in the program pursuant to
//the contract and the program should not be copied or distributed
//outside your organization.  The DOE and the University of
//North Carolina reserve all rights in the program. Neither the authors,
//University of North Carolina, or U.S. Government make any warranty,
//express or implied, or assume any liability or responsibility
//for the use of this software.
//-------------------------------------------------------------

#import "ORFlashCamReadoutModel.h"
#import "ORFlashCamADCModel.h"
#import "ORFlashCamTriggerModel.h"
#import "bufio.h"

NSString* ORFlashCamReadoutModelIPAddressChanged    = @"ORFlashCamReadoutModelIPAddressChanged";
NSString* ORFlashCamReadoutModelUsernameChanged     = @"ORFlashCamReadoutModelUsernameChanged";
NSString* ORFlashCamReadoutModelEthInterfaceChanged = @"ORFlashCamReadoutModelEthInterfaceChanged";
NSString* ORFlashCamReadoutModelEthInterfaceAdded   = @"ORFlashCamReadoutModelEthInterfaceAdded";
NSString* ORFlashCamReadoutModelEthInterfaceRemoved = @"ORFlashCamReadoutModelEthInterfaceRemoved";
NSString* ORFlashCamReadoutModelEthTypeChanged      = @"ORFlashCamReadoutModelEthTypeChanged";
NSString* ORFlashCamReadoutModelConfigParamChanged  = @"ORFlashCamReadoutModelConfigParamChanged";
NSString* ORFlashCamReadoutModelFCSourcePathChanged = @"ORFlashCamReadoutModelFCSourcePathChanged";
NSString* ORFlashCamReadoutModelPingStart           = @"ORFlashCamReadoutModelPingStart";
NSString* ORFlashCamReadoutModelPingEnd             = @"ORFlashCamReadoutModelPingEnd";
NSString* ORFlashCamReadoutModelRemotePathStart     = @"ORFlashCamReadoutModelRemotePathStart";
NSString* ORFlashCamReadoutModelRemotePathEnd       = @"ORFlashCamReadoutModelRemotePathEnd";
NSString* ORFlashCamReadoutModelRunInProgress       = @"ORFlashCamReadoutModelRunInProgress";
NSString* ORFlashCamReadoutModelRunEnded            = @"ORFlashCamReadoutModelRunEnded";
NSString* ORFlashCamReadoutModelListenerChanged     = @"ORFlashCamReadoutModelListenerChanged";
NSString* ORFlashCamReadoutModelListenerAdded       = @"ORFlashCamReadoutModelListenerAdded";
NSString* ORFlashCamReadoutModelListenerRemoved     = @"ORFlashCamReadoutModelListenerRemoved";

static NSString* ORFlashCamReadoutModelEthConnectors[kFlashCamMaxEthInterfaces] =
{ @"FlashCamEthInterface0", @"FlashCamEthInterface1",
  @"FlashCamEthInterface2", @"FlashCamEthInterface3"};

@implementation ORFlashCamReadoutModel

#pragma mark •••Initialization

- (id) init
{
    self = [super init];
    [[self undoManager] disableUndoRegistration];
    [self setIPAddress:@""];
    [self setUsername:@""];
    ethInterface     = [[NSMutableArray array] retain];
    [self setEthType:@"efb1"];
    configParams = [[NSMutableDictionary dictionary] retain];
    validFCSourcePath = false;
    [self setFCSourcePath:@"--"];
    checkedFCSourcePath = false;
    [self setConfigParam:@"maxPayload"    withValue:[NSNumber numberWithInt:0]];
    [self setConfigParam:@"eventBuffer"   withValue:[NSNumber numberWithInt:1000]];
    [self setConfigParam:@"phaseAdjust"   withValue:[NSNumber numberWithInt:-1]];
    [self setConfigParam:@"baselineSlew"  withValue:[NSNumber numberWithInt:0]];
    [self setConfigParam:@"integratorLen" withValue:[NSNumber numberWithInt:7]];
    [self setConfigParam:@"eventSamples"  withValue:[NSNumber numberWithInt:2048]];
    [self setConfigParam:@"signalDepth"   withValue:[NSNumber numberWithInt:1024]];
    [self setConfigParam:@"traceType"     withValue:[NSNumber numberWithInt:1]];
    [self setConfigParam:@"pileupRej"     withValue:[NSNumber numberWithDouble:0.0]];
    [self setConfigParam:@"logTime"       withValue:[NSNumber numberWithDouble:1000.0]];
    [self setConfigParam:@"gpsEnabled"    withValue:[NSNumber numberWithBool:NO]];
    [self setConfigParam:@"incBaseline"   withValue:[NSNumber numberWithBool:YES]];
    pingTask = nil;
    pingSuccess = NO;
    remotePathTask = nil;
    firmwareTasks = nil;
    firmwareQueue = [[NSMutableArray array] retain];
    runFailedAlarm = nil;
    [[self undoManager] enableUndoRegistration];
    return self;
}

- (void) dealloc
{
    [ipAddress release];
    [username release];
    if(ethInterface) [ethInterface release];
    [ethType release];
    if(configParams) [configParams release];
    if(pingTask) [pingTask release];
    if(remotePathTask) [remotePathTask release];
    if(firmwareTasks) [firmwareTasks release];
    if(firmwareQueue) [firmwareQueue release];
    if(runFailedAlarm){
        [runFailedAlarm clearAlarm];
        [runFailedAlarm release];
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [super dealloc];
}

- (void) makeMainController
{
    [self linkToController:@"ORFlashCamReadoutController"];
}

- (void) setUpImage
{
    NSImage* cimage = [NSImage imageNamed:@"flashcam"];
    NSSize size = [cimage size];
    NSSize newsize;
    newsize.width  = 0.5*size.width;
    newsize.height = 0.5*size.height;
    NSImage* image = [[NSImage alloc] initWithSize:newsize];
    [image lockFocus];
    NSRect rect;
    rect.origin = NSZeroPoint;
    rect.size.width = newsize.width;
    rect.size.height = newsize.height;
    [cimage drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [image unlockFocus];
    [self setImage:image];
}

- (void) makeConnectors
{
    float dx = ([self frame].size.width -kConnectorSize) / (kFlashCamMaxEthInterfaces - 1);
    for(int i=0; i<kFlashCamMaxEthInterfaces; i++){
        ORConnector* connector = [[ORConnector alloc] initAt:NSMakePoint([self x]+i*dx, [self y])
                                                withGuardian:self
                                              withObjectLink:self];
        //[connector setIoType:kInputConnector];
        [connector setConnectorImageType:kSmallDot];
        [connector setConnectorType:'FCEI'];
        [connector addRestrictedConnectionType:'FCEO'];
        [connector setOffColor:[NSColor colorWithCalibratedRed:1 green:1 blue:0.3 alpha:1]];
        [connector setOnColor:[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:1 alpha:1]];
        if(i >= [self ethInterfaceCount]) [connector setHidden:YES];
        [[self connectors] setObject:connector forKey:ORFlashCamReadoutModelEthConnectors[i]];
        [connector release];
    }
}

#pragma mark •••Accessors

- (NSString*) identifier
{
    return [NSString stringWithFormat:@"readout %d", [self uniqueIdNumber]];
}

- (NSString*) ipAddress
{
    if(!ipAddress) return @"";
    return ipAddress;
}

- (NSString*) username
{
    if(!username) return @"";
    return username;
}

- (bool) localMode
{
    if([ipAddress isEqualToString:@"localhost"] || [ipAddress isEqualToString:@"127.0.0.1"]) return true;
    return false;
}

- (int) ethInterfaceCount
{
    if(!ethInterface) return 0;
    return (int) [ethInterface count];
}

- (int) indexOfInterface:(NSString*)interface
{
    if(!interface || !ethInterface) return -1;
    for(int i=0; i<[self ethInterfaceCount]; i++){
        NSString* eth = [self ethInterfaceAtIndex:i];
        if(!eth) continue;
        if([eth isEqualToString:interface]) return i;
    }
    return -1;
}

- (NSString*) ethInterfaceAtIndex:(int)index
{
    if(index < 0 || index >= [self ethInterfaceCount]) return nil;
    return [[[ethInterface objectAtIndex:index] copy] autorelease];
}

- (NSString*) ethType
{
    if(!ethType) return @"";
    return ethType;
}

- (NSNumber*) configParam:(NSString*)p
{
    if([p isEqualToString:@"maxPayload"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"maxPayload"] intValue]];
    else if([p isEqualToString:@"eventBuffer"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"eventBuffer"] intValue]];
    else if([p isEqualToString:@"phaseAdjust"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"phaseAdjust"] intValue]];
    else if([p isEqualToString:@"baselineSlew"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"baselineSlew"] intValue]];
    else if([p isEqualToString:@"integratorLen"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"integratorLen"] intValue]];
    else if([p isEqualToString:@"eventSamples"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"eventSamples"] intValue]];
    else if([p isEqualToString:@"signalDepth"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"signalDepth"] intValue]];
    else if([p isEqualToString:@"traceType"])
        return [NSNumber numberWithInt:[[configParams objectForKey:@"traceType"] intValue]];
    else if([p isEqualToString:@"pileupRej"])
        return [NSNumber numberWithDouble:[[configParams objectForKey:@"pileupRej"] doubleValue]];
    else if([p isEqualToString:@"logTime"])
        return [NSNumber numberWithDouble:[[configParams objectForKey:@"logTime"] doubleValue]];
    else if([p isEqualToString:@"gpsEnabled"])
        return [NSNumber numberWithBool:[[configParams objectForKey:@"gpsEnabled"] boolValue]];
    else if([p isEqualToString:@"incBaseline"])
        return [NSNumber numberWithBool:[[configParams objectForKey:@"incBaseline"] boolValue]];
    else{
        NSLog(@"ORFlashCamReadoutModel - unknown configuration parameter %@\n", p);
        return nil;
    }
}

- (NSString*) fcSourcePath
{
    return fcSourcePath;
}

- (bool) validFCSourcePath
{
    return validFCSourcePath;
}

- (bool) pingSuccess
{
    return pingSuccess;
}

- (ORTaskSequence*) remotePathTask
{
    if(!remotePathTask){
        remotePathTask = [[ORTaskSequence taskSequenceWithDelegate:self] retain];
        [remotePathTask setVerbose:NO];
        [remotePathTask setTextToDelegate:YES];
    }
    return remotePathTask;
}

- (int) listenerCount
{
    return (int) [self count];
}

- (ORFlashCamListenerModel*) getListenerAtIndex:(int)i
{
    if(i >= 0 && i < [self count]) return [self objectAtIndex:i];
    return nil;
}

- (ORFlashCamListenerModel*) getListener:(NSString *)eth atPort:(uint16_t)p
{
    for(ORFlashCamListenerModel* l in [self orcaObjects]) if([l sameIP:eth andPort:p]) return l;
    return nil;
}

- (ORFlashCamListenerModel*) getListenerForIP:(NSString*)ip atPort:(uint16_t)p
{
    for(ORFlashCamListenerModel* l in [self orcaObjects]) if([l sameIP:ip andPort:p]) return l;
    return nil;
}

- (int) getIndexOfListener:(NSString *)eth atPort:(uint16_t)p
{
    for(int i=0; i<[self listenerCount]; i++)
        if([[self getListenerAtIndex:i] sameInterface:eth andPort:p]) return i;
    return -1;
}

- (void) setIPAddress:(NSString*)ip
{
    if(!ip) return;
    if(!ipAddress) ipAddress = @"";
    [[[self undoManager] prepareWithInvocationTarget:self] setIPAddress:[self ipAddress]];
    [ipAddress autorelease];
    ipAddress = [ip copy];
    [self checkFCSourcePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelIPAddressChanged object:self];
}

- (void) setUsername:(NSString*)user
{
    if(!user) return;
    if(!username) username = @"";
    [[[self undoManager] prepareWithInvocationTarget:self] setUsername:[self username]];
    [username autorelease];
    username = [user copy];
    [self checkFCSourcePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelUsernameChanged object:self];
}

- (void) addEthInterface:(NSString*)eth
{
    if(!eth) return;
    if(!ethInterface) ethInterface = [[NSMutableArray array] retain];
    if([self indexOfInterface:eth] >= 0) return;
    [ethInterface addObject:[eth copy]];
    if([self ethInterfaceCount] <= kFlashCamMaxEthInterfaces){
        int i = [self ethInterfaceCount] - 1;
        [[[self connectors] objectForKey:ORFlashCamReadoutModelEthConnectors[i]] setHidden:NO];
        [[NSNotificationCenter defaultCenter] postNotificationName:ORConnectionChanged object:self];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelEthInterfaceAdded object:self];
}

- (void) setEthInterface:(NSString*)eth atIndex:(int)index
{
    if(!eth) return;
    if(index < 0 || index >= [self ethInterfaceCount]) return;
    if([self indexOfInterface:eth] == index) return;
    NSString* tmp = [[ethInterface objectAtIndex:index] copy];
    [[ethInterface objectAtIndex:index] autorelease];
    if([self indexOfInterface:eth] < 0){
        [ethInterface setObject:eth atIndexedSubscript:index];
        for(int i=0; i<[self listenerCount]; i++){
            NSMutableArray* remoteInterfaces = [[self getListenerAtIndex:i] remoteInterfaces];
            for(NSUInteger j=0; j<[remoteInterfaces count]; j++){
                if([[remoteInterfaces objectAtIndex:j] isEqualToString:tmp])
                    [remoteInterfaces setObject:eth atIndexedSubscript:j];
            }
            [[self getListenerAtIndex:i] setRemoteInterfaces:remoteInterfaces];
        }
    }
    else{
        [ethInterface setObject:@"" atIndexedSubscript:index];
        for(int i=0; i<[self listenerCount]; i++){
            NSMutableArray* remoteInterfaces = [[self getListenerAtIndex:i] remoteInterfaces];
            for(NSUInteger j=0; j<[remoteInterfaces count]; j++){
                if([[remoteInterfaces objectAtIndex:j] isEqualToString:tmp])
                    [remoteInterfaces removeObjectAtIndex:j];
            }
            [[self getListenerAtIndex:i] setRemoteInterfaces:remoteInterfaces];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelEthInterfaceChanged object:self];
}

- (void) removeEthInterface:(NSString*)eth
{
    [self removeEthInterfaceAtIndex:[self indexOfInterface:eth]];
}

- (void) removeEthInterfaceAtIndex:(int)index
{
    if(index < 0 || index >= [self ethInterfaceCount]) return;
    for(int i=0; i<[self listenerCount]; i++){
        NSMutableArray* remoteInterfaces = [[self getListenerAtIndex:i] remoteInterfaces];
        for(NSUInteger j=0; j<[remoteInterfaces count]; j++){
            if([[remoteInterfaces objectAtIndex:j] isEqualToString:[ethInterface objectAtIndex:index]])
                [remoteInterfaces removeObjectAtIndex:j];
        }
        [[self getListenerAtIndex:i] setRemoteInterfaces:remoteInterfaces];
    }
    [ethInterface removeObjectAtIndex:index];
    if([self ethInterfaceCount] < kFlashCamMaxEthInterfaces){
        int i = [self ethInterfaceCount];
        [[[self connectors] objectForKey:ORFlashCamReadoutModelEthConnectors[i]] disconnect];
        [[[self connectors] objectForKey:ORFlashCamReadoutModelEthConnectors[i]] setHidden:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:ORConnectionChanged object:self];
    }
    NSDictionary* info = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:index] forKey:@"index"];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelEthInterfaceRemoved object:self userInfo:info];
}

- (void) setEthType:(NSString*)eth
{
    if(!eth) return;
    if(!ethType) ethType = @"efb1";
    [[[self undoManager] prepareWithInvocationTarget:self] setEthType:[self ethType]];
    for(int i=1; i<=5; i++) if([eth isEqualToString:[NSString stringWithFormat:@"efb%d",i]]) ethType = [eth copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelEthTypeChanged object:self];
}

- (void) setConfigParam:(NSString*)p withValue:(NSNumber*)v
{
    // fixme: put in limits on parameters below
    if([p isEqualToString:@"maxPayload"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"maxPayload"];
    else if([p isEqualToString:@"eventBuffer"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"eventBuffer"];
    else if([p isEqualToString:@"phaseAdjust"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"phaseAdjust"];
    else if([p isEqualToString:@"baselineSlew"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"baselineSlew"];
    else if([p isEqualToString:@"integratorLen"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"integratorLen"];
    else if([p isEqualToString:@"eventSamples"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"eventSamples"];
    else if([p isEqualToString:@"signalDepth"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"signalDepth"];
    else if([p isEqualToString:@"traceType"])
        [configParams setObject:[NSNumber numberWithInt:[v intValue]] forKey:@"traceType"];
    else if([p isEqualToString:@"pileupRej"])
        [configParams setObject:[NSNumber numberWithDouble:[v doubleValue]] forKey:@"pileupRej"];
    else if([p isEqualToString:@"logTime"])
        [configParams setObject:[NSNumber numberWithDouble:[v doubleValue]] forKey:@"logTime"];
    else if([p isEqualToString:@"gpsEnabled"])
        [configParams setObject:[NSNumber numberWithBool:[v boolValue]] forKey:@"gpsEnabled"];
    else if([p isEqualToString:@"incBaseline"])
        [configParams setObject:[NSNumber numberWithBool:[v boolValue]] forKey:@"incBaseline"];
    else{
        NSLog(@"ORFlashCamReadoutModel - unknown configuration parameter %@\n", p);
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelConfigParamChanged object:self];
}

- (void) setFCSourcePath:(NSString*)path
{
    if(fcSourcePath) if([path isEqualToString:fcSourcePath]) return;
    fcSourcePath = [path copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelFCSourcePathChanged object:self];
}

- (void) addListener:(ORFlashCamListenerModel*)listener
{
    for(int i=0; i<[self listenerCount]; i++) if(listener == [self getListenerAtIndex:i]) return;
    if([self listenerCount] >= kFlashCamMaxListeners){
        NSLog(@"ORFlashCamReadoutModel: maximum of 8 listeners currently supported\n");
    }
    [self addObject:[listener retain]];
    NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInt:[self listenerCount]-1],
                          @"index", [NSNumber numberWithInt:(int)[listener tag]], @"tag", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelListenerAdded object:info];
}

- (void) addListener:(NSString*)eth atPort:(uint16_t)p
{
    if([self getListener:eth atPort:p]){
        NSLog(@"ORFlashCamReadoutModel: cannot add listener with identical interface %@ and port %d\n", eth, (int)p);
        return;
    }
    ORFlashCamListenerModel* l = [[[ORFlashCamListenerModel alloc] initWithInterface:eth port:p] retain];
    [self addObject:l];
    NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInt:[self listenerCount]-1],
                          @"index", [NSNumber numberWithInt:(int)[l tag]], @"tag", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelListenerAdded object:info];
}

- (void) setListener:(NSString*)eth atPort:(uint16_t)p forIndex:(int)i
{
    if(i <0 || i >= [self listenerCount]) return;
    int j = [self getIndexOfListener:eth atPort:p];
    if(i == j) return;
    else if(j != -1){
        NSLog(@"ORFlashCamReadoutModel: cannot set listeners with identical interface %@ and port %d\n", eth, (int)p);
        return;
    }
    ORFlashCamListenerModel* l = [self getListenerAtIndex:i];
    if(!l){
        l = [[[ORFlashCamListenerModel alloc] initWithInterface:eth port:p] retain];
        [[self orcaObjects] setObject:l atIndexedSubscript:i];
        NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:i],
                              @"index", [NSNumber numberWithInt:(int)[l tag]], @"tag", nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelListenerAdded object:info];
    }
    else{
        if([[l interface] isEqualToString:eth] && [l port] == p) return;
        [l setInterface:eth andPort:p];
        NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:i],
                              @"index", [NSNumber numberWithInt:(int)[l tag]], @"tag", nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelListenerChanged object:info];
    }
}

- (void) removeListener:(NSString*)eth atPort:(uint16_t)p
{
    [self removeListenerAtIndex:[self getIndexOfListener:eth atPort:p]];
}

- (void) removeListenerAtIndex:(int)i
{
    if(i < 0 || i >= [self listenerCount]) return;
    int t = (int) [[self getListenerAtIndex:i] tag];
    [[[self orcaObjects] objectAtIndex:i] autorelease];
    [[self orcaObjects] removeObjectAtIndex:i];
    NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInt:i], @"index", [NSNumber numberWithInt:t], @"tag", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelListenerRemoved object:info];
}


#pragma mark •••Commands

- (void) updateIPs
{
    for(int i=0; i<[self listenerCount]; i++){
        ORFlashCamListenerModel* l = [self getListenerAtIndex:i];
        if(l) [l updateIP];
    }
}

- (void) sendPing:(bool)verbose
{
    if(!pingTask){
        pingSuccess = NO;
        pingTask = [[ORPingTask pingTaskWithDelegate:self] retain];
        pingTask.launchPath = @"/sbin/ping";
        pingTask.arguments = [NSArray arrayWithObjects:@"-c", @"1", @"-t", @"1", @"-q", ipAddress, nil];
        pingTask.verbose = verbose;
        pingTask.textToDelegate = YES;
        [pingTask ping];
        [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelPingStart object:self];
    }
}

- (bool) pingRunning
{
    return pingTask != nil;
}

- (void) getRemotePath
{
    [[self remotePathTask] addTask:[[[NSBundle mainBundle] resourcePath] stringByAppendingString:@"/remote_path"]
                         arguments:[NSArray arrayWithObjects:username, ipAddress, @"printenv", @"|", @"grep", @"FLASHCAMDIR", nil]];
    [[self remotePathTask] launch];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelRemotePathStart object:self];
    checkedFCSourcePath = false;
}

- (void) checkFCSourcePath
{
    if([fcSourcePath isEqualToString:@""] || [fcSourcePath isEqualToString:@"--"] || !ipAddress || !username){
        if(validFCSourcePath)
            [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelFCSourcePathChanged object:self];
        validFCSourcePath = false;
        checkedFCSourcePath = true;
        return;
    }
    if([self localMode]){
        bool prev = validFCSourcePath;
        NSString* p = [[fcSourcePath stringByExpandingTildeInPath] stringByAppendingString:@"/server/readout-fc250b"];
        if([[NSFileManager defaultManager] fileExistsAtPath:p]) validFCSourcePath = true;
        else{
            validFCSourcePath = false;
            NSLogColor([NSColor redColor], @"ORFlashCamReadoutModel: readout executable not found at %@\n", p);
        }
        if(prev != validFCSourcePath)
            [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelFCSourcePathChanged object:self];
    }
    else{
        NSString* readout = [fcSourcePath stringByAppendingString:@"/server/readout-fc250b"];
        [[self remotePathTask] addTask:[[[NSBundle mainBundle] resourcePath] stringByAppendingString:@"/remote_path"]
                             arguments:[NSArray arrayWithObjects:username, ipAddress, @"ls", readout, nil]];
        [remotePathTask launch];
        [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelRemotePathStart object:self];
    }
    checkedFCSourcePath = true;
}

- (void) taskFinished:(id)task
{
    if(task == pingTask){
        [pingTask release];
        pingTask = nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelPingEnd object:self];
    }
}

- (void) tasksCompleted:(id)sender
{
    if(sender == firmwareTasks){
        [firmwareTasks release];
        firmwareTasks = nil;
        if([firmwareQueue count] > 0){
            [self getFirmwareVersion:[firmwareQueue objectAtIndex:0]];
            [firmwareQueue removeObjectAtIndex:0];
        }
    }
    else if(sender == remotePathTask){
        [remotePathTask release];
        remotePathTask = nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelRemotePathEnd object:self];
        if(!checkedFCSourcePath) [self checkFCSourcePath];
        else if(![self localMode] && !validFCSourcePath)
            NSLogColor([NSColor redColor], @"ORFlashCamReadoutModel: readout executable not found on %@ at %@, check that $FLASHCAMDIR is set and contains server/readout-fc250b\n", ipAddress, fcSourcePath);
    }
}

- (void) taskData:(NSDictionary*)taskData
{
    id        task = [[taskData objectForKey:@"Task"] retain];
    NSString* text = [[taskData objectForKey:@"Text"] retain];
    if(task == pingTask){
        if([text rangeOfString:@" 0.0% packet loss"].location != NSNotFound) pingSuccess = YES;
        else pingSuccess = NO;
    }
    else if(task == remotePathTask && text){
        bool prev = validFCSourcePath;
        NSRange r = [text rangeOfString:@"FLASHCAMDIR="];
        if(r.location != NSNotFound){
            NSString* tmp = [text substringWithRange:NSMakeRange(r.location+r.length,
                                                                 [text length]-r.location-r.length)];
            [self setFCSourcePath:[[tmp componentsSeparatedByString:@" "] objectAtIndex:0]];
        }
        else if([text rangeOfString:@"No such file or directory"].location != NSNotFound) validFCSourcePath = false;
        else if([text rangeOfString:@"readout-fc250b"].location != NSNotFound) validFCSourcePath = true;
        if(prev != validFCSourcePath)
            [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelFCSourcePathChanged object:self];
    }
    [task release];
    [text release];
}

- (int) ethIndexForCard:(ORCard*)card
{
    for(int i=0; i<(int)[ethInterface count]; i++){
        NSMutableArray* objs = [self connectedObjects:[card className] toInterface:[self ethInterfaceAtIndex:i]];
        if([objs containsObject:card]) return i;
    }
    return -1;
}

- (NSMutableArray*) runFlags
{
    NSMutableArray* f = [NSMutableArray array];
    //[f addObjectsFromArray:@[@"-mt",   [NSString stringWithFormat:@"%d", runLength]]];
    [f addObjectsFromArray:@[@"-et",   [self ethType]]];
    [f addObjectsFromArray:@[@"-mpl",  [NSString stringWithFormat:@"%d", [[self configParam:@"maxPayload"]    intValue]]]];
    [f addObjectsFromArray:@[@"-slots",[NSString stringWithFormat:@"%d", [[self configParam:@"eventBuffer"]   intValue]]]];
    [f addObjectsFromArray:@[@"-aph",  [NSString stringWithFormat:@"%d", [[self configParam:@"phaseAdjust"]   intValue]]]];
    [f addObjectsFromArray:@[@"-bls",  [NSString stringWithFormat:@"%d", [[self configParam:@"baselineSlew"]  intValue]]]];
    [f addObjectsFromArray:@[@"-il",   [NSString stringWithFormat:@"%d", [[self configParam:@"integratorLen"] intValue]]]];
    [f addObjectsFromArray:@[@"-es",   [NSString stringWithFormat:@"%d", [[self configParam:@"eventSamples"]  intValue]]]];
    [f addObjectsFromArray:@[@"-sd",   [NSString stringWithFormat:@"%d", [[self configParam:@"signalDepth"] intValue]]]];
    [f addObjectsFromArray:@[@"-gt",   [NSString stringWithFormat:@"%d", [[self configParam:@"traceType"]     intValue]]]];
    [f addObjectsFromArray:@[@"-gpr",[NSString stringWithFormat:@"%.2f", [[self configParam:@"pileupRej"]  doubleValue]]]];
    //[f addObjectsFromArray:@[@"-lt", [NSString stringWithFormat:@"%.2f", [[self configParam:@"logTime"]    doubleValue]]]];
    [f addObjectsFromArray:@[@"-gps",  [NSString stringWithFormat:@"%d", [[self configParam:@"gpsEnabled"]    intValue]]]];
    [f addObjectsFromArray:@[@"-blinc",[NSString stringWithFormat:@"%d", [[self configParam:@"incBaseline"]   intValue]]]];
    return f;
}

- (NSMutableArray*) connectedObjects:(NSString*)cname toInterface:(NSString*)eth
{
    NSMutableArray* objs = [NSMutableArray array];
    if(!cname || !eth) return objs;
    int index = [self indexOfInterface:eth];
    if(index < 0 || index >= kFlashCamMaxEthInterfaces) return objs;
    ORConnector* connector = [connectors objectForKey:ORFlashCamReadoutModelEthConnectors[index]];
    if(!connector) return objs;
    if(![connector isConnected]) return objs;
    id obj = [connector connectedObject];
    if(!obj) return objs;
    if([[obj className] isEqualToString:cname])
        [objs addObject:obj];
    else if([[obj className] isEqualToString:@"ORFlashCamEthLinkModel"])
        [obj addObjectsFromArray:[obj connectedObjects:cname]];
    return objs;
}

- (NSMutableArray*) connectedObjects:(NSString*)cname
{
    NSMutableArray* objs = [NSMutableArray array];
    for(int i=0; i<MIN(kFlashCamMaxEthInterfaces, [self ethInterfaceCount]); i++)
        [objs addObjectsFromArray:[self connectedObjects:cname toInterface:[self ethInterfaceAtIndex:i]]];
    return objs;
}

- (void) getFirmwareVersion:(ORFlashCamCard*)card
{
    if(!card) return;
    [self sendPing:NO];
    [self getFirmwareVersionAfterPing:card];
}

- (void) getFirmwareVersionAfterPing:(ORFlashCamCard*)card
{
    if(!card) return;
    if(firmwareTasks) [firmwareQueue addObject:card];
    if([self pingRunning]) [self performSelector:@selector(getFirmwareVersionAfterPing:) withObject:card afterDelay:0.05];
    else{
        if(!pingSuccess){
            NSLog(@"ORFlashCamReadoutModel: ping failure, aborting firmware version check\n");
            [card taskFinished:nil];
            return;
        }
        NSMutableArray* args = [NSMutableArray array];
        [args addObjectsFromArray:@[username, ipAddress, @"./fwl-fc250b"]];
        int eindex = [self ethIndexForCard:card];
        if(eindex < 0){
            NSLog(@"ORFlashCamReadoutModel: cannot retrieve firmware version, card not connected\n");
            return;
        }
        [args addObjectsFromArray:@[@"-ei", [self ethInterfaceAtIndex:eindex]]];
        [args addObjectsFromArray:@[@"-et", ethType]];
        [args addObjectsFromArray:@[[NSString stringWithFormat:@"%x", [card cardAddress]]]];
        firmwareTasks = [[ORTaskSequence taskSequenceWithDelegate:card] retain];
        [firmwareTasks setVerbose:NO];
        [firmwareTasks setTextToDelegate:YES];
        [firmwareTasks addTask:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"remote_run"]
                     arguments:args];
        [firmwareTasks launch];
    }
}

- (void) startRunAfterPing
{
    // if any firmware tasks are still running, wait
    /*if(firmwareTasks){
        [self performSelector:@selector(startRunAfterPing) withObject:self afterDelay:0.2];
        return;
    }*/
    // if the ping task is still running, wait
    if([self pingRunning]){
        [self performSelector:@selector(startRunAfterPing) withObject:self afterDelay:0.01];
        return;
    }
    // if the ping failed, don't attempt to start the runs
    if(!pingSuccess){
        NSLogColor([NSColor redColor], @"ORFlashCamReadoutModel: ping failure aborting remote run\n");
        [self runFailed];
        return;
    }
    NSMutableArray* args = [NSMutableArray array];
    if(![self localMode]) [args addObjectsFromArray:@[username, ipAddress, @"readout-fc250b"]];
    [args addObjectsFromArray:[self runFlags]];
    for(int i=0; i<[self listenerCount]; i++) [[self getListenerAtIndex:i] setReadOutArgs:args];
}

- (void) runFailed
{
    [[NSNotificationCenter defaultCenter] postNotificationName:ORRequestRunHalt object:self];
    if(!runFailedAlarm){
        runFailedAlarm = [[ORAlarm alloc] initWithName:@"FlashCam host failed to start run"
                                              severity:kRunInhibitorAlarm];
        [runFailedAlarm setSticky:NO];
    }
    if(![runFailedAlarm isPosted]){
        [runFailedAlarm setAcknowledged:NO];
        [runFailedAlarm postAlarm];
    }
}

/*- (void) killRun
{
    // kill any flashcam readout processes running on the remote host
    NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
    ORTaskSequence* tasks = [ORTaskSequence taskSequenceWithDelegate:self];
    [tasks setVerbose:YES];
    [tasks addTask:[resourcePath stringByAppendingPathComponent:@"kill_run"]
         arguments:[NSArray arrayWithObjects:username, ipAddress,
                    @"/usr/bin/pkill", @"-c", @"readout-fc", nil]];
    [tasks setTextToDelegate:YES];
    [tasks launch];
    // abort any remaining run tasks
    if(runTasks != nil) [runTasks abortTasks];
    [[NSNotificationCenter defaultCenter] postNotificationName:ORFlashCamReadoutModelRunEnded object:self];
}*/


#pragma mark •••OrOrderedObjHolding Protocol
- (int) maxNumberOfObjects           { return 8; }
- (int) objWidth                     { return 45; }
- (int) groupSeparation              { return 0;  }
- (int) numberSlotsNeededFor:(id)obj { return 1; }

- (NSString*) nameForSlot:(int)slot
{
    return [NSString stringWithFormat:@"Slot %d", slot];
}

- (NSRange) legalSlotsForObj:(id)obj
{
    if(![obj isKindOfClass:NSClassFromString(@"ORFlashCamListenerModel")]) return NSMakeRange(0, 0);
    if([self listenerCount] >= [self maxNumberOfObjects]) return NSMakeRange(0, 0);
    return NSMakeRange(0, [self maxNumberOfObjects]);
}

- (int) slotAtPoint:(NSPoint)point
{
    return floor(((int) point.x) / [self objWidth]);
}

- (NSPoint) pointForSlot:(int)slot;
{
    return NSMakePoint(slot*[self objWidth], 0);
}

- (void) place:(id)obj intoSlot:(int)slot
{
    [(OrcaObject*)obj setTag:slot];
    [obj moveTo:[self pointForSlot:slot]];
}

- (int) slotForObj:(id)obj
{
    return (int) [obj tag];
}

- (BOOL) slot:(int)aSlot excludedFor:(id)anObj
{
    return NO;
}

- (void) drawSlotBoundaries
{
    NSBezierPath* path = [NSBezierPath bezierPath];
    for(int i=1; i<[self maxNumberOfObjects]; i++){
        float x = i * [self objWidth];
        [path moveToPoint:NSMakePoint(x, 0)];
        [path lineToPoint:NSMakePoint(x, [self objWidth])];
    }
    [[NSColor systemBlueColor] set];
    [path stroke];
}

- (void) drawSlotLabels
{
    for(int i=0; i<[self maxNumberOfObjects]; i++){
        NSString* s = [NSString stringWithFormat:@"%d",i];
        NSAttributedString* slotLabel = [[NSAttributedString alloc]
                                        initWithString:s
                                            attributes:[NSDictionary dictionaryWithObjectsAndKeys:
                                                        [NSFont messageFontOfSize:8],NSFontAttributeName,
                                                        [NSColor systemBlueColor],
                                                        NSForegroundColorAttributeName,nil]];
        NSSize textSize = [slotLabel size];
        float x = (i*[self objWidth])+[self objWidth]/2. - textSize.width/2;
        [slotLabel drawInRect:NSMakeRect(x,2,textSize.width,textSize.height)];
        [slotLabel release];
    }
}


#pragma mark •••Data taker methods

- (void) takeData:(ORDataPacket*)aDataPacket userInfo:(NSDictionary*)userInfo
{
}

- (void) runTaskStarted:(ORDataPacket*)aDataPacket userInfo:(NSDictionary*)userInfo
{
    if(runFailedAlarm) [runFailedAlarm clearAlarm];
    // check that we can ping the remote host
    [self sendPing:NO];
    // now wait for the ping task and start the run if successful
    [self startRunAfterPing];
}

- (void) runTaskStopped:(ORDataPacket*)aDataPacket userInfo:(NSDictionary*)userInfo
{
}

- (void) reset
{
}

#pragma mark •••Archival

- (id) initWithCoder:(NSCoder*)decoder
{
    self = [super initWithCoder:decoder];
    [[self undoManager] disableUndoRegistration];
    [self setIPAddress:      [decoder decodeObjectForKey:@"ipAddress"]];
    [self setUsername:       [decoder decodeObjectForKey:@"username"]];
    ethInterface =     [[decoder decodeObjectForKey:@"ethInterface"] retain];
    [self setEthType:        [decoder decodeObjectForKey:@"ethType"]];
    configParams = [[decoder decodeObjectForKey:@"configParams"] retain];
    validFCSourcePath = false;
    [self setFCSourcePath:[decoder decodeObjectForKey:@"fcSourcePath"]];
    if(!fcSourcePath) fcSourcePath = @"--";
    checkedFCSourcePath = false;
    if(ipAddress) if(![ipAddress isEqualToString:@""]) [self checkFCSourcePath];
    pingTask = nil;
    pingSuccess = NO;
    remotePathTask = nil;
    firmwareTasks = nil;
    if(!firmwareQueue) firmwareQueue = [[NSMutableArray array] retain];
    [[self undoManager] enableUndoRegistration];
    return self;
}

- (void) encodeWithCoder:(NSCoder*)encoder
{
    [super encodeWithCoder:encoder];
    [encoder encodeObject:ipAddress        forKey:@"ipAddress"];
    [encoder encodeObject:username         forKey:@"username"];
    [encoder encodeObject:ethInterface     forKey:@"ethInterface"];
    [encoder encodeObject:ethType          forKey:@"ethType"];
    [encoder encodeObject:configParams     forKey:@"configParams"];
    [encoder encodeObject:fcSourcePath     forKey:@"fcSourcePath"];
}

@end
