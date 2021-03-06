/****************************************************************************************************
	Observable.mm
	Observable

	Created by Chall Fry on 8/18/13.
    Copyright (c) 2013-2014 eBay Software Foundation.
*/

#import "DebugUtils.h"
#include <sys/sysctl.h>
#import <objc/runtime.h>
#import <libgen.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <map>

#import "EBNObservableInternal.h"


static Class EBNShadowed_ClassForCoder(id self, SEL _cmd);
template<typename T> void overrideSetterMethod(NSString *propName, Method setter, Method getter,
		Class classToModify);
extern "C" { void EBN_RunLoopObserverCallBack(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info); }
bool AmIBeingDebugged (void);

	// Keeping track of delayed blocks
static NSMutableSet				*EBN_ObserverBlocksToRunAfterThisEvent;
static NSMutableSet 			*EBN_ObservedObjectKeepAlive;

	// Shadow classes--private subclasses that we create to implement overriding setter methods
	// Both of these dictionaries hold EBNShadowedClassInfo objects, and are keyed with Class objects
NSMutableDictionary				*EBNBaseClassToShadowInfoTable;
NSMutableDictionary				*EBNShadowedClassToInfoTable;

	// Not used for anything other than as a @synchronize token.
void							*EBNObservableSynchronizationToken;

/***********************************************************************************/

#pragma mark -
@implementation EBNKeypathEntryInfo

- (NSString *) debugDescription
{
	NSString *returnStr = [NSString stringWithFormat:@"Path:\"%@\": %@", self->_keyPath,
			[self->_blockInfo debugDescription]];
	return returnStr;
}

@end

/***********************************************************************************/

#pragma mark -
@implementation EBNShadowedClassInfo

- (instancetype) initWithClass:(Class) newShadowClass
{
	if (self = [super init])
	{
		self->_shadowClass = newShadowClass;
		self->_getters = [[NSMutableSet alloc] init];
		self->_setters = [[NSMutableSet alloc] init];
	}
	return self;
}
@end

#pragma mark -
@implementation EBNObservable

#pragma mark Public API

/****************************************************************************************************
	init
	
	Xcode 5 has the designated initializer annotation, but it doesn't work right for classes that don't
	declare any initializers? Hmm.
*/
- (id) init
{
	if (self = [super init])
	{
	}
	
	return self;
}

/****************************************************************************************************
	tell:when:changes:
	
	Sets up KVO. When the given property is modified (specifically, its setter method is called),
	the given block will be called before the end of the current event on the main thread's runloop.
*/
- (EBNObservation *) tell:(id) observer when:(NSString *) keyPathString changes:(ObservationBlock) callBlock
{
	EBNObservation *blockInfo = [[EBNObservation alloc] initForObserved:self
			observer:observer block:callBlock] ;
	
	[self observe:keyPathString using:blockInfo];
	
	return blockInfo;
}

/****************************************************************************************************
	tell:whenAny:changes:
	
	Sets up KVO for a bunch of properties at once. A change to any property in the list will 
	cause the given block to be called. Multiple changes to properties during the processing
	of a single event in the main thread's runloop will be coalesced.
	
	The callBlock is always called on the main thread, at the end of event processing. Note that 
	changes to properties on another thread aren't guaranteed to be coalesced, but probably 
	will be.
*/
- (EBNObservation *) tell:(id) observer whenAny:(NSArray *) propertyList changes:(ObservationBlock) callBlock
{
	EBNObservation *blockInfo = [[EBNObservation alloc] initForObserved:self
			observer:observer block:callBlock] ;

	for (NSString *keyPathString in propertyList)
	{
		[self observe:keyPathString using:blockInfo];
	}
	
	return blockInfo;
}

/****************************************************************************************************
	stopTelling:aboutChangesTo:
	
	Deregisters all notifications for a particular keypath that notify the givenlistener. 
	Usually this is one observation block, as this is usally the 'remove one KVO observation' call.
	But there can be multiple blocks registered by the same observer to view the same keypath.
*/
- (void) stopTelling:(id) observer aboutChangesTo:(NSString *) keyPathStr
{
	NSArray *keyPath = [keyPathStr componentsSeparatedByString:@"."];
	NSString *propName = keyPath[0];
	NSMutableSet *entriesToRemove = [[NSMutableSet alloc] init];
	
	// Look for the case where we're removing 'object-following' array elements. This case
	// doesn't yet work well.
	for (NSString *pathEntry in keyPath)
	{
		if (isdigit([pathEntry characterAtIndex:0]))
		{
			EBLogContext(kLoggingContextOther, @"Ending observation on array elements where the observation is "
			@"referenced by the keypath doesn't work very well. Perhaps you should use one of the other stopTelling: "@"methods instead.");
		}
	}
	
	// Find all the entries to be removed
	@synchronized(EBNObservableSynchronizationToken)
	{
		NSMapTable *observerTable = self->_observedMethods[propName];
		for (EBNKeypathEntryInfo *entry in observerTable)
		{
			if (entry->_blockInfo->_weakObserver_forComparisonOnly == observer && [keyPath isEqualToArray:entry->_keyPath])
			{
				NSInteger index = [[observerTable objectForKey:entry] integerValue];
				if (index == 0)
				{
					// We've found the right entry. Call the recursive remove method.
					[entriesToRemove addObject:entry];
				}
			}
		}
	}
	
	// And then remove them
	for (EBNKeypathEntryInfo *entry in entriesToRemove)
	{
		[self removeKeypath:entry atIndex:0];
	}
}

/****************************************************************************************************
	stopTelling:aboutChangesToArray:
	
	The companion method for tell:whenAny:changes:.
*/
- (void) stopTelling:(id) observer aboutChangesToArray:(NSArray *) propertyList
{
	for (NSString *propName in propertyList)
	{
		[self stopTelling:observer aboutChangesTo:propName];
	}
}

/****************************************************************************************************
	stopTellingAboutChanges:
	
	Stop telling the given observer object about all changes to any known property.
*/
- (void) stopTellingAboutChanges:(id) observer
{
	int removedBlockCount = 0;
	NSMutableSet *entriesToRemove = [[NSMutableSet alloc] init];

	@synchronized(EBNObservableSynchronizationToken)
	{
		for (NSString *propertyKey in [self->_observedMethods allKeys])
		{
			NSMapTable *observerTable = self->_observedMethods[propertyKey];
			
			for (EBNKeypathEntryInfo *entryInfo in observerTable)
			{
				// We're only looking for the blocks for which this is the observed object.
				NSInteger index = [[observerTable objectForKey:entryInfo] integerValue];
				if (entryInfo->_blockInfo->_weakObserver_forComparisonOnly == observer && index == 0)
				{
					[entriesToRemove addObject:entryInfo];
					++removedBlockCount;
				}
			}
		}
	}

	for (EBNKeypathEntryInfo *entryInfo in entriesToRemove)
	{
		[self removeKeypath:entryInfo atIndex:0];
	}

	// Show warnings for odd results
	if (removedBlockCount == 0)
	{
		EBLogContext(kLoggingContextOther, @"When removing all observer blocks where %@ is observing %@: "
				@"Couldn't find any matching observer block. Were we not observering this?",
				[observer class], [self class]);
	}
}

/****************************************************************************************************
	stopAllCallsTo:
	
	If you saved your observationBlock when you registered, you can use this method to 
	remove all KVO notifications for this object that'd call that block.
	
	Must be sent to the same object that you sent the "tell:" method to when you set up the observation,
	but matches any keypath. That is, this won't remove an observation whose keypath goes through or
	ends at this object, only ones that start at this object.
*/
- (void) stopAllCallsTo:(ObservationBlock) stopBlock
{
	int removedBlockCount = 0;
	NSMutableSet *entriesToRemove = [[NSMutableSet alloc] init];

	@synchronized(EBNObservableSynchronizationToken)
	{
		for (NSString *propertyKey in [self->_observedMethods allKeys])
		{
			NSMapTable *observerTable = self->_observedMethods[propertyKey];
			
			for (EBNKeypathEntryInfo *entryInfo in observerTable)
			{
				// Match on the entries where the block that gets run is the indicated block
				NSInteger index = [[observerTable objectForKey:entryInfo] integerValue];
				if (entryInfo->_blockInfo->_copiedBlock == stopBlock && index == 0)
				{
					[entriesToRemove addObject:entryInfo];
					++removedBlockCount;
				}
			}
		}
	}
	
	for (EBNKeypathEntryInfo *entryInfo in entriesToRemove)
	{
		[self removeKeypath:entryInfo atIndex:0];
	}

	// Show warnings for odd results
	if (removedBlockCount == 0)
	{
		EBLogContext(kLoggingContextOther, @"When stopping all cases where %@ calls observer block %p: "
				@"Couldn't find any matching observer block. Were we not observering this?",
				[self debugDescription], stopBlock);
	}

}

#pragma mark Protected Stuff for Subclasses

/****************************************************************************************************
	property:observationStateIs:
	
	Because Obj-C doesn't have pure virtual methods, and it's easier to just call a method instead
	of seeing if it exists.
*/
- (void) property:(NSString *)propName observationStateIs:(BOOL)isBeingObserved
{
	// Do nothing. Subclasses can override this.
}

/****************************************************************************************************
	valueForKeyEBN:
	
	Cocoa collection classes implement valueForKey: to perform operations on each object in the colleciton.
	They also don't allow observing for sets and arrays. Since we do, we need a valueForKey: variant
	that allows you to pass a key string into a collection and get back the corresponding object
	from the collection. 
	
	That is, [observableArray valueForKeyEBN:@"4"] will give you object 4 in the array, just like array[4].
*/
- (id) valueForKeyEBN:(NSString *)key
{
	return [self valueForKey:key];
}

/****************************************************************************************************
	manuallyTriggerObserversForProperty:previousValue:
	
	Manually adds the observers for the given property to the list of observers to call. Useful
	if a observed object needs to use direct ivar access yet still wants to trigger observers.
	
	It's important for this method to not get the new value of the property unless it needs to in
	order to perform observation path upkeep.
*/
- (void) manuallyTriggerObserversForProperty:(NSString *) propertyName previousValue:(id) prevValue
{
	NSMapTable *observerTable = nil;
	@synchronized(EBNObservableSynchronizationToken)
	{
		observerTable = [self->_observedMethods[propertyName] copy];
	}
	
	if (!observerTable)
		return;
		
	for (EBNKeypathEntryInfo *entry in observerTable)
	{
		// If the property that changed had a observation on it that was in the
		// middle of the keypath's observation, fix up the observation keypath.
		EBNObservation *blockInfo = entry->_blockInfo;
		NSInteger index = [[observerTable objectForKey:entry] integerValue];
		if (index != [entry->_keyPath count] - 1)
		{
			id newValue = [self valueForKeyEBN:propertyName];
			if (newValue != prevValue)
			{
				[prevValue removeKeypath:entry atIndex:index + 1];
				[newValue createKeypath:entry atIndex:index + 1];
			}
		}

		// Make sure the observed object still exists before calling/scheduling blocks
		EBNObservable *strongObserved = blockInfo->_weakObserved;
		if (strongObserved)
		{
			// Execute any immediate blocks
			if (blockInfo->_copiedImmedBlock)
			{
				[blockInfo executeWithPreviousValue:prevValue];
			}
		
			// Schedule any delayed blocks; also keep the observed object alive until the delayed block is called.
			if (blockInfo->_copiedBlock)
			{
				@synchronized(EBNObservableSynchronizationToken)
				{
					[EBN_ObserverBlocksToRunAfterThisEvent addObject:blockInfo];
					[EBN_ObservedObjectKeepAlive addObject:strongObserved];
				}
			}
		} else
		{
			[self reapBlocks];
		}
	}
}

/****************************************************************************************************
	manuallyTriggerObserversForProperty:previousValue:newValue:
	
	Manually adds the observers for the given property to the list of observers to call. Useful
	if a observed object needs to use direct ivar access yet still wants to trigger observers.
*/
- (void) manuallyTriggerObserversForProperty:(NSString *) propertyName previousValue:(id) prevValue
		newValue:(id) newValue
{
	if (newValue != prevValue || [propertyName isEqualToString:@"*"])
	{
		NSMapTable *observerTable = nil;
		@synchronized(EBNObservableSynchronizationToken)
		{
			observerTable = [self->_observedMethods[propertyName] copy];
		}
		
		if (!observerTable)
			return;
			
		for (EBNKeypathEntryInfo *entry in observerTable)
		{
			// If the property that changed had a observation on it that was in the
			// middle of the keypath's observation, fix up the observation keypath.
			EBNObservation *blockInfo = entry->_blockInfo;
			NSInteger index = [[observerTable objectForKey:entry] integerValue];
			if (index != [entry->_keyPath count] - 1)
			{
				[prevValue removeKeypath:entry atIndex:index + 1];
				[newValue createKeypath:entry atIndex:index + 1];
			}

			// Make sure the observed object still exists before calling/scheduling blocks
			EBNObservable *strongObserved = blockInfo->_weakObserved;
			if (strongObserved)
			{
				// Execute any immediate blocks
				if (blockInfo->_copiedImmedBlock)
				{
					[blockInfo executeWithPreviousValue:prevValue];
				}
			
				// Schedule any delayed blocks; also keep the observed object alive until the delayed block is called.
				if (blockInfo->_copiedBlock)
				{
					@synchronized(EBNObservableSynchronizationToken)
					{
						[EBN_ObserverBlocksToRunAfterThisEvent addObject:blockInfo];
						[EBN_ObservedObjectKeepAlive addObject:strongObserved];
					}
				}
			} else
			{
				[self reapBlocks];
			}
		}
	}
}

/****************************************************************************************************
	numberOfObservers:
	
	Returns the number of observers for the given property.
*/
- (NSUInteger) numberOfObservers:(NSString *) propertyName
{
	// Clean out any observation blocks that are inactive because their observer went away.
	// We don't want to count them.
	[self reapBlocks];
	
	@synchronized(EBNObservableSynchronizationToken)
	{
		NSMutableSet *observerTable = self->_observedMethods[propertyName];
		NSUInteger numObservers = [observerTable count];
		return numObservers;
	}
}

/****************************************************************************************************
	allObservedProperties
	
	Returns all the properties currently being observed, as an array of strings. This includes
	properties being observed because a keypath rooted at some other object runs through (or ends at)
	this object.
*/
- (NSArray *) allObservedProperties
{
	[self reapBlocks];
	
	NSArray *properties = nil;
	@synchronized(EBNObservableSynchronizationToken)
	{
		properties = [self->_observedMethods allKeys];
	}
	
	return properties;
}

#pragma mark Private

/****************************************************************************************************
	initialize
	
	Because static initialization is so great.
	
	Sets up a global set of blocks to be run on the main runloop, and creates a run loop observer
	to iterate the set.
*/
+ (void) initialize
{
	// Only set up the global block set and run loop observer once, and do it for the base class.
	if (self == [EBNObservable class])
	{
		// The dispatch_once is probably not necessary, as initialize is guaranteed to be called
		// exactly once, and the base init is guaranteed to be called before subclass inits
		// (therefore before subclasses can access the wrapper block queue).
		static dispatch_once_t once;
		dispatch_once(&once,
		^{
			// Set up our set of blocks to run at the end of each event
			EBN_ObserverBlocksToRunAfterThisEvent = [[NSMutableSet alloc] init];
			CFRunLoopObserverRef ref = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, YES, 0,
					EBN_RunLoopObserverCallBack, NULL);
			CFRunLoopAddObserver(CFRunLoopGetMain(), ref, kCFRunLoopDefaultMode);
			
			// And, this is our set of objects to keep from getting dealloc'ed until we can
			// send their observer messages.
			EBN_ObservedObjectKeepAlive = [[NSMutableSet alloc] init];

			//
			EBNShadowedClassToInfoTable = [[NSMutableDictionary alloc] init];
			EBNBaseClassToShadowInfoTable = [[NSMutableDictionary alloc] init];
		});
	}
}

/****************************************************************************************************
	dealloc
	
	Cleans up the KVO tables, and calls observedObjectHasBeenDeallocated: on any observers that
	implement the method.
*/
- (void) dealloc
{
	NSMutableSet *objectsToNotify = [NSMutableSet set];
	
	@synchronized(EBNObservableSynchronizationToken)
	{
		for (NSMapTable *observerTable in [self->_observedMethods allValues])
		{
			for (EBNKeypathEntryInfo *entryInfo in [observerTable copy])
			{
				// Remove all 'downstream' keypath parts; they'll become inaccessable after
				// this object goes away. This case should only really be hit when this object
				// is weakly held by its 'upstream' object's keypath property.
				NSInteger index = [[observerTable objectForKey:entryInfo] integerValue];
				[self removeKeypath:entryInfo atIndex:index];
				
				if (index == 0)
				{
					// Only notify using DeallocProtocol for observations where this object is the base
					// of the keypath. That is, observer notifications where the notification itself
					// is going away because this object is the root of the keypath.
					id object = entryInfo->_blockInfo->_weakObserver;
					if (object && [object respondsToSelector:@selector(observedObjectHasBeenDealloced:endingObservation:)])
					{
						[objectsToNotify addObject:entryInfo];
					}
				}
				
				// If index != 0, we could trigger observer notifications here, as the 'upstream'
				// object likely holds us with a __weak or __unsafe_unretained property and won't
				// notify via normal means when we get dealloced.
				//
				// But, this only works for properties that are of type EBNObservable and subclasses.
				// Other properties of object type (which would have to be endpoint properties)
				// wouldn't do this.
			}
		}
	}
	
	for (EBNKeypathEntryInfo *entry in objectsToNotify)
	{
		id observer = entry->_blockInfo->_weakObserver;
		NSMutableString *keyPathStr = [[NSMutableString alloc] init];
		NSString *separator = @"";
		for (NSString *prop in entry->_keyPath)
		{
			[keyPathStr appendFormat:@"%@%@", separator, prop];
			separator = @".";
		}
		[observer observedObjectHasBeenDealloced:self endingObservation:keyPathStr];
	}
}

/****************************************************************************************************
	observe:using:
	
*/
- (bool) observe:(NSString *) keyPathString using:(EBNObservation *) blockInfo
{
	// Create our keypath entry
	EBNKeypathEntryInfo	*entryInfo = [[EBNKeypathEntryInfo alloc] init];
	entryInfo->_keyPath = [keyPathString componentsSeparatedByString:@"."];
	entryInfo->_blockInfo = blockInfo;
	
	for (int index = 0; index < [entryInfo->_keyPath count] - 1; ++index)
	{
		EBAssert(![entryInfo->_keyPath[index] isEqualToString:@"*"],
				@"Only the final part of a keypath can use the '*' operator.");
	}

	bool kvoSetUp = [self createKeypath:entryInfo atIndex:0];
	EBAssert(kvoSetUp, @"Unable to set up observation on keypath %@", keyPathString);
	
	return kvoSetUp;
}

/****************************************************************************************************
	createKeypath:atIndex:
	
	Keypaths look like "a.b.c.d" where "a" is an EBNObservable object, "b" and "c" are 
	properties of the object before them (and are also of type EBNObservable), and "d" is a
	property of "c" but can have any valid property type.
	
	The index argument tells this method what part of the keypath it's setting up. This method works
	by setting up observation on one property of one object, and then if this isn't the end of the 
	keypath it calls the createKeypath method of the next object in the path, incrementing
	the index argument in the call.

	If the current property value of the non-endpoint property being observed is nil, we stop
	setting up observation on the keypath. If the property's value changes to non-nil in the 
	future, createKeypath:atIndex: is called to continue setting up the keypath. Similarly,
	if the property value changes, the 'old' keypath from that point is removed, and a new
	one is built from the changed property value to the end of the keypath.
	
	Returns TRUE if the keypath was set up successfully.
*/
- (bool) createKeypath:(const EBNKeypathEntryInfo *) entryInfo atIndex:(NSInteger) index
{
	// Get the property name we'll be adding observation on
	NSString *propName = entryInfo->_keyPath[index];
	
	// If this is a '*' observation, observe all properties via recusive calls
	if ([propName isEqualToString:@"*"])
	{
		Class curClass = [self class];

		// The current class must be a subclass of Observable; copyPropertyList only gives us properties
		// about the current class--not it's superclasses.
		// So, walk up the class tree, from the current class to Observable.
		while (curClass != [EBNObservable class])
		{
			unsigned int propCount;
			objc_property_t *properties = class_copyPropertyList(curClass, &propCount);
			if (properties)
			{
				for (int propIndex = 0; propIndex < propCount; ++propIndex)
				{
					// If any particular observe fails, it's okay (probably means a readonly property)
					NSString *propString = @(property_getName(properties[propIndex]));
					if (propString)
					{
						[self createKeypath:entryInfo atIndex:index forProperty:propString];
					}
				}
			
				free(properties);
			}
			
			curClass = [curClass superclass];
		}
	} else
	{
		return [self createKeypath:entryInfo atIndex:index forProperty:propName];
	}
	
	return true;
}

/****************************************************************************************************
	createKeypath:atIndex:forProperty:
	
	Keypaths look like "a.b.c.d" where "a" is an EBNObservable object, "b" and "c" are 
	properties of the object before them (and are also of type EBNObservable), and "d" is a
	property of "c" but can have any valid property type.
	
	The index argument tells this method what part of the keypath it's setting up. This method works
	by setting up observation on one property of one object, and then if this isn't the end of the 
	keypath it calls the createKeypath method of the next object in the path, incrementing
	the index argument in the call.

	If the current property value of the non-endpoint property being observed is nil, we stop
	setting up observation on the keypath. If the property's value changes to non-nil in the 
	future, createKeypath:atIndex: is called to continue setting up the keypath. Similarly,
	if the property value changes, the 'old' keypath from that point is removed, and a new
	one is built from the changed property value to the end of the keypath.
	
	Returns TRUE if the keypath was set up successfully.
*/
- (bool) createKeypath:(const EBNKeypathEntryInfo *) entryInfo atIndex:(NSInteger) index
		forProperty:(NSString *) propName
{
	bool success = false;
	bool tableWasEmpty = false;

	// Check that this class is set up to observe the given property. That is, check that we've
	// swizzled the setter.
	[self swizzleImplementationForSetter:propName];

	@synchronized(EBNObservableSynchronizationToken)
	{
		// Make sure we've initialized our observed methods dictionary and properties set
		if (!self->_observedMethods)
		{
			self->_observedMethods = [[NSMutableDictionary alloc] init];
		}
	
		NSMapTable *observerTable = self->_observedMethods[propName];

		// Check for the case where this entryInfo is already in the table. Since
		// there's one entryInfo for each keypath, this likely indicates a property loop
		NSNumber *keypathIndex = [observerTable objectForKey:entryInfo];
		if (keypathIndex)
		{
			EBAssert([keypathIndex integerValue] != index, @"This keypath entry is already being observed? Shouldn't happen.");
			EBAssert([keypathIndex integerValue] == index, @"This appears to be property loop? Observable can't handle these.");
		}
		
		// Check for the case where the observer is already observing this property
		id observer = entryInfo->_blockInfo->_weakObserver;
		if (observer)
		{
			for (EBNKeypathEntryInfo *entry in observerTable)
			{
				if (entry->_blockInfo->_weakObserver == observer && [entry->_keyPath isEqualToArray:entryInfo->_keyPath])
				{
					EBLogContext(kLoggingContextOther,
							@"%@: While adding a new observer: The observer object (%@) is already "
							@"observing the property %@. This is sometimes okay, but more often an error.",
							[self class], [observer debugDescription], propName);
				}
			}
		}
	
		// Now get the set of blocks to invoke when a particular setter is called.
		// If the set doesn't exist, create it and add it to the method dict.
		if (!observerTable)
		{
			observerTable = [NSMapTable strongToStrongObjectsMapTable];
			self->_observedMethods[propName] = observerTable;
			tableWasEmpty = true;
		}
				
		[observerTable setObject:[NSNumber numberWithInteger:index] forKey:entryInfo];
	}
	
	if (index == [entryInfo->_keyPath count] - 1)
	{
		// If this is the endoint, we're done.
		success = true;
	} else
	{
		// Not endoint. Move to the next property in the chain, and recurse.
		id<EBNObservableProtocol> next = (id<EBNObservableProtocol>) [self valueForKeyEBN:propName];
		if (next)
		{
			EBAssert([next conformsToProtocol:@protocol(EBNObservableProtocol)],
					@"Every property in a keypath needs to conform to <EBNObservableProtocol>");
			success = [next createKeypath:entryInfo atIndex:index + 1];
		} else
		{
			// If the property value is nil, we can't recurse any farther, but it also means
			// we've successfully setup observation.
			success = true;
		}
	}
		
	// If the table had been empty, but now isn't, this means the given property
	// is now being observed (and wasn't before now). Inform ourselves.
	if (tableWasEmpty)
		[self property:propName observationStateIs:TRUE];
		
	return success;
}

/****************************************************************************************************
	removeKeypath:atIndex:

	Removes the observation on the property at the given index into the given keypath entry,
	(which should map to a property of this object), and then calls removeKeypath:atIndex:
	with index + 1 on the next object in the keypath. Stops when we get to the endpoint property.
	
	When a property in the middle of an observed keypath changes value, this method gets called
	as the 'old' path is removed (and then the 'new' path gets built).
	
	Returns TRUE if the observation path was removed successfully.
*/
- (bool) removeKeypath:(const EBNKeypathEntryInfo *) entryInfo atIndex:(NSInteger) index
{
	if (index >= [entryInfo->_keyPath count])
		return false;

	NSString *propName = entryInfo->_keyPath[index];
	
	// If this is a '*' observation, remove all observations via recursive calls
	if ([propName isEqualToString:@"*"])
	{
		NSArray *properties = nil;
		@synchronized(EBNObservableSynchronizationToken)
		{
			properties = [self->_observedMethods allKeys];
		}
		
		for (NSString *property in properties)
		{
			[self removeKeypath:entryInfo atIndex:index forProperty:property];
		}
	} else
	{
		return [self removeKeypath:entryInfo atIndex:index forProperty:propName];
	}
	
	return true;
}

/****************************************************************************************************
	removeKeypath:atIndex:forProperty:

	Removes the observation on the property at the given index into the given keypath entry,
	(which should map to a property of this object), and then calls removeKeypath:atIndex:
	with index + 1 on the next object in the keypath. Stops when we get to the endpoint property.
	
	When a property in the middle of an observed keypath changes value, this method gets called
	as the 'old' path is removed (and then the 'new' path gets built).
	
	Returns TRUE if the observation path was removed successfully.
*/
- (bool) removeKeypath:(const EBNKeypathEntryInfo *) entryInfo atIndex:(NSInteger) index
		forProperty:(NSString *) propName
{
	bool observerTableRemoved = false;

	// Remove the entry from the observer table for the given property.
	@synchronized(EBNObservableSynchronizationToken)
	{
		NSMapTable *observerTable = self->_observedMethods[propName];
		[observerTable removeObjectForKey:entryInfo];
		
		// Could check for duplicate entries and reap zeroed entries here
		
		if (![observerTable count])
		{
			[self->_observedMethods removeObjectForKey:propName];
			observerTableRemoved = true;
		}
	}
	
	// If this isn't the endpoint property, recurse--call this same method in the
	// next object in the keypath
	if (index < [entryInfo->_keyPath count] - 1)
	{
		EBNObservable *next = [self valueForKeyEBN:propName];
		if (next)
		{
			[next removeKeypath:entryInfo atIndex:index + 1];
		}
	}
	
	// If nobody is observing this property anymore, inform ourselves
	if (observerTableRemoved)
	{
		[self property:propName observationStateIs:false];
	}
	
	return observerTableRemoved;
}

/****************************************************************************************************
	reapBlocks

	Checks every registered block in this object, removing blocks whose observer has been deallocated.
	This method will tell other Observable objects to remove entries for keypaths where their observing
	object has been deallocated.
	
	Rember that the lifetime of an observer block should be until either the observed or observing
	object goes away (or it's explicitly removed). However, since there isn't a notifying zeroing 
	weak pointer, we do this to clean up.
	
	Returns the number of blocks that got reaped.
*/
- (int) reapBlocks
{
	int removedBlockCount = 0;
	NSMutableSet *entriesToRemove = [[NSMutableSet alloc] init];

	@synchronized(EBNObservableSynchronizationToken)
	{
		for (NSString *propertyKey in [self->_observedMethods allKeys])
		{
			NSMapTable *observerTable = self->_observedMethods[propertyKey];
			for (EBNKeypathEntryInfo *entry in observerTable)
			{
				if (!entry->_blockInfo->_weakObserver)
				{
					[entriesToRemove addObject:entry];
				}
			}
		}
	}
		
	for (EBNKeypathEntryInfo *entry in entriesToRemove)
	{
		EBNObservable *strongObserved = entry->_blockInfo->_weakObserved;
		if (strongObserved)
		{
			[strongObserved removeKeypath:entry atIndex:0];
			++removedBlockCount;
		}
	}

	return removedBlockCount;
}

/****************************************************************************************************
	selectorForPropertySetter:
	
	Returns the SEL for a given property's setter method, given the name of the property as a string 
	(NOT the name of the setter method). The SEL will be a valid instance method for this
	class, or nil.
*/
+ (SEL) selectorForPropertySetter:(NSString *) propertyName
{
	// If this is an actual declared property, get the property, then its property attributes string,
	// then pull out the setter method from the string.
	const char *propName = [propertyName UTF8String];
	objc_property_t prop = class_getProperty(self, propName);
	if (prop)
	{
		char *propString = property_copyAttributeValue(prop, "S");
		if (propString)
		{
			SEL methodSel = sel_registerName(propString);
			if (methodSel && [self instancesRespondToSelector:methodSel])
			{
				return methodSel;
			}
		}
	}
	
	// Even if it's not a declared property, we can still sometimes find the setter.
	// Try to guess the setter name by prepending "set" and uppercasing the first char of the propname
	char setterName[200] = "_set";
	strncpy(setterName + 4, propName, 190);
	setterName[4] = toupper(setterName[4]);
	strncat(setterName, ":", 1);
	
	SEL methodSel = sel_registerName(setterName + 1);
	if (methodSel && [self instancesRespondToSelector:methodSel])
		return methodSel;
	methodSel = sel_registerName(setterName);
	if (methodSel && [self instancesRespondToSelector:methodSel])
		return methodSel;
	
	return nil;
}

/****************************************************************************************************
	selectorForPropertyGetter:
	
	Returns the SEL for a given property's getter method, given the name of the property as a string
	(NOT the name of the setter method). The SEL will be a valid instance method for this
	class, or nil.
*/
+ (SEL) selectorForPropertyGetter:(NSString *) propertyName
{
	NSString *getterName = nil;
	SEL methodSel;
	Method getterMethod;

	// Check the case where the getter has the same name as the property
	methodSel = NSSelectorFromString(propertyName);
	getterMethod = class_getInstanceMethod(self, methodSel);
	if (getterMethod && method_getNumberOfArguments(getterMethod) == 2)
	{
		return methodSel;
	}

	// If the property has a custom getter, go find it by getting the property attribute string
	objc_property_t prop = class_getProperty(self, [propertyName UTF8String]);
	if (prop)
	{
		NSString *propStr = [NSString stringWithUTF8String:property_getAttributes(prop)];
		NSRange getterStartRange =[propStr rangeOfString:@",G"];
		if (getterStartRange.location != NSNotFound)
		{
			// The property attribute string has a bunch of stuff in it, we're looking for a substring
			// in the format ",GisVariable," or ",GisVariable" at the end of the string
			NSInteger searchStart = getterStartRange.location + getterStartRange.length;
			NSRange nextCommaSearchRange = NSMakeRange(searchStart, [propStr length] - searchStart);
			NSRange nextComma = [propStr rangeOfString:@"," options:0 range:nextCommaSearchRange];
			if (nextComma.location == NSNotFound)
				getterName = [propStr substringWithRange:nextCommaSearchRange];
			else
				getterName = [propStr substringWithRange:NSMakeRange(searchStart, nextComma.location - searchStart)];

			// See if the getter method name actually has a Method
			methodSel = NSSelectorFromString(getterName);
			getterMethod = class_getInstanceMethod(self, methodSel);
			if (getterMethod && method_getNumberOfArguments(getterMethod) == 2)
				return methodSel;
		}
	}
	
	// Try prepending an underscore to the getter name
	getterName = [NSString stringWithFormat:@"_%@", propertyName];
	methodSel = NSSelectorFromString(getterName);
	getterMethod = class_getInstanceMethod(self, methodSel);
	if (getterMethod && method_getNumberOfArguments(getterMethod) == 2)
	{
		return methodSel;
	}
	
	return nil;
}

/****************************************************************************************************
	prepareToObserveProperty
	
	This returns the class where we should add/replace getter and setter methods in order to 
	implement observation.
	
	This class should be a runtime-created subclass of the given class. It could be a class created
	by Apple's KVO, or one created by us.
*/
- (Class) prepareToObserveProperty:(NSString *)propertyName isSetter:(bool) isSetter
{
	//
	Class curClass = object_getClass(self);
	EBNShadowedClassInfo *info = nil;
	bool mustSetMethodImplementation = false;
	
	@synchronized (EBNBaseClassToShadowInfoTable)
	{
		// 1. Is this object already shadowed?
		info = EBNShadowedClassToInfoTable[curClass];

		if (!info)
		{
			// 2. Do we have a shadow class for this base object class already?
			info = EBNBaseClassToShadowInfoTable[curClass];
			if (info)
			{
				// In this case we have to make the object be the shadow class
				object_setClass(self, info->_shadowClass);
			}
		}
		
		if (!info)
		{
			// 3. Check to see if the current object's class is a runtime-created subclass of our
			// runtime-created subclass of the original object class.
			Class shadowClass = class_getSuperclass(curClass);
			while (shadowClass && shadowClass != [EBNObservable class])
			{
				info = EBNShadowedClassToInfoTable[shadowClass];
				if (info)
				{
					// In this instance curClass isn't the base class--it's somebody else's
					// private subclass. BUT, our private subclass is a superclass of their
					// private subclass, so we can cache it as if curClass was our shadow class. Easy, right?
					[EBNShadowedClassToInfoTable setObject:info forKey:curClass];
					break;
				}
			
				shadowClass = class_getSuperclass(shadowClass);
			}
		}
	
		if (!info)
		{
			// 4. If this object is subclassed by Apple's KVO, we can't subclass their subclass.
			// Apple's code becomes unhappy, apparently. So instead we'll method swizzle methods in
			// Apple's KVO subclass.
			if ([self class] == class_getSuperclass(curClass))
			{
				info = [[EBNShadowedClassInfo alloc] initWithClass:curClass];
				info->_isAppleKVOClass = true;
				[EBNShadowedClassToInfoTable setObject:info forKey:curClass];
			}
		}
	
		if (!info)
		{
			// Have to make a new class
			NSString *shadowClassName = [NSString stringWithFormat:@"%s_EBNShadowClass",
					class_getName([self class])];
			Class shadowClass = objc_allocateClassPair([self class], [shadowClassName UTF8String], 0);
			if (!shadowClass)
			{
				// In some odd cases (such as multiple classes with the same name in your codebase) allocate
				// class pair will fail. In that case try to find the proper shadow class to use.
			//	shadowClass = objc_getClass([shadowClassName UTF8String]);
			//	info = EBNShadowedClassToInfoTable[shadowClass];
			}
			else
			{
				// Override classForCoder to return the parent class; this keeps us from encoding the
				// shadowed class with NSCoder
				Method classForCoder = class_getInstanceMethod(curClass, @selector(classForCoder));
				class_addMethod(shadowClass, @selector(classForCoder), (IMP) EBNShadowed_ClassForCoder,
						method_getTypeEncoding(classForCoder));
			
				// This is where we'd override Class for the shadowed class...
			
				// And then we have to register the new class.
				objc_registerClassPair(shadowClass);
				
				// Add our new class to the table
				info = [[EBNShadowedClassInfo alloc] initWithClass:shadowClass];
				[EBNBaseClassToShadowInfoTable setObject:info forKey:[self class]];
				[EBNShadowedClassToInfoTable setObject:info forKey:shadowClass];
			}

			if (info)
				object_setClass(self, info->_shadowClass);
		}
		
		// If after all this we don't have an info object, we need to bail as we can't observe this.
		if (!info)
			return nil;
		
		// Check to see if the getter/setter has been overridden in this class.
		if (isSetter)
		{
			if (![info->_setters containsObject:propertyName])
			{
				mustSetMethodImplementation = true;
				[info->_setters addObject:propertyName];
			}
		}
		else
		{
			if (![info->_getters containsObject:propertyName])
			{
				mustSetMethodImplementation = true;
				[info->_getters addObject:propertyName];
			}
		}
	}
	
	if (mustSetMethodImplementation)
		return info->_shadowClass;
	
	return nil;
}

/****************************************************************************************************
	swizzleImplementationForSetter:
	
	Swizzles the implemention of the setter method of the given property. The swizzled implementation
	calls through to the original implementation and then processes observer blocks.
	
	The bulk of this method is a switch statement that switches on the type of the property (parsed
	from the string returned by method_getArgumentType()) and calls a templatized C++ function
	called overrideSetterMethod<>() to create a new method and swizzle it in.
*/
- (bool) swizzleImplementationForSetter:(NSString *) propName
{
	// This checks to see if we've made a subclass for observing, and if that subclass has
	// an override for the setter method for the given property. It returns the class that we need
	// to modify iff we need to override the setter.
	Class classToModify = [self prepareToObserveProperty:propName isSetter:YES];
	if (!classToModify)
		return true;
	
	// The setter doesn't need to be found, although we still return false.
	// This is what will happen for readonly properties in a keypath.
	SEL setterSelector = [[self class] selectorForPropertySetter:propName];
	if (!setterSelector)
		return false;
		
	// For the setter we'll need the method definition, so we can get the argument type
	// As with the selector, this could be nil (in this case it means that some other class
	// defines the setter method, but the property is readonly in this class).
	Method setterMethod = class_getInstanceMethod([self class], setterSelector);
	if (!setterMethod)
		return false;
	
	// The getter really needs to be found. For keypath properties, we need to use the getter
	// to figure out what object to move to next; for endpoint properties, we use the getter
	// to determine if the value actually changes when the setter is called.
	SEL getterSelector = [[self class] selectorForPropertyGetter:propName];
	EBAssert(getterSelector, @"Couldn't find getter method for property %@ in object %@", propName, self);
	if (!getterSelector)
		return false;
	
	// Get the getter method.
	Method getterMethod = class_getInstanceMethod([self class], getterSelector);
	EBAssert(getterMethod, @"Could not find getter method. Make sure class %@ has a method named %@.",
			[self class], NSStringFromSelector(getterSelector));
		
	char typeOfSetter[32];
	method_getArgumentType(setterMethod, 2, typeOfSetter, 32);

	// Types defined in runtime.h
	switch (typeOfSetter[0])
	{
	case _C_CHR:
		overrideSetterMethod<char>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_UCHR:
		overrideSetterMethod<unsigned char>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_SHT:
		overrideSetterMethod<short>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_USHT:
		overrideSetterMethod<unsigned short>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_INT:
		overrideSetterMethod<int>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_UINT:
		overrideSetterMethod<unsigned int>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_LNG:
		overrideSetterMethod<long>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_ULNG:
		overrideSetterMethod<unsigned long>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_LNG_LNG:
		overrideSetterMethod<long long>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_ULNG_LNG:
		overrideSetterMethod<unsigned long long>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_FLT:
		overrideSetterMethod<float>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_DBL:
		overrideSetterMethod<double>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_BFLD:
		// Pretty sure this can't happen, as bitfields can't be top-level and are only found inside structs/unions
		EBAssert(false, @"Observable does not have a way to override the setter for %@.",
				propName);
	break;
	case _C_BOOL:
		overrideSetterMethod<bool>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_PTR:
	case _C_CHARPTR:
	case _C_ATOM:		// Apparently never generated? Only docs I can find say treat same as charptr
	case _C_ARY_B:
		overrideSetterMethod<void *>(propName, setterMethod, getterMethod, classToModify);
	break;
	
	case _C_ID:
		overrideSetterMethod<id>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_CLASS:
		overrideSetterMethod<Class>(propName, setterMethod, getterMethod, classToModify);
	break;
	case _C_SEL:
		overrideSetterMethod<SEL>(propName, setterMethod, getterMethod, classToModify);
	break;

	case _C_STRUCT_B:
		if (!strncmp(typeOfSetter, @encode(NSRange), 32))
			overrideSetterMethod<NSRange>(propName, setterMethod, getterMethod, classToModify);
		else if (!strncmp(typeOfSetter, @encode(CGPoint), 32))
			overrideSetterMethod<CGPoint>(propName, setterMethod, getterMethod, classToModify);
		else if (!strncmp(typeOfSetter, @encode(CGRect), 32))
			overrideSetterMethod<CGRect>(propName, setterMethod, getterMethod, classToModify);
		else if (!strncmp(typeOfSetter, @encode(CGSize), 32))
			overrideSetterMethod<CGSize>(propName, setterMethod, getterMethod, classToModify);
		else
			EBAssert(false, @"Observable does not have a way to override the setter for %@.",
					propName);
	break;
	
	case _C_UNION_B:
		// If you hit this assert, look at what we do above for structs, make something like that for
		// unions, and add your type to the if statement
		EBAssert(false, @"Observable does not have a way to override the setter for %@.",
				propName);
	break;
	
	default:
		EBAssert(false, @"Observable does not have a way to override the setter for %@.",
				propName);
	break;
	}
	
	return true;
}

#pragma mark Debugging KVO

/****************************************************************************************************
	debugBreakOnChange:
	
*/
- (NSString *) debugBreakOnChange:(NSString *) keyPath
{
	return [self debugBreakOnChange:keyPath line:0 file:NULL func:NULL];
}

/****************************************************************************************************
	debugBreakOnChange:
	
	Meant to be used with the DebugBreakOnChange() macro. 
	
	Will break in the debugger when the property value at the end of the given keypath is changed. 
	Sort of like a breakpoint on the setter, but only for this object. Sort of like a watchpoint,
	but without the terrible slowness. 
	
	To use, type something like this into lldb:
	
		po DebugBreakOnChange(object, @"propertyName")
*/
- (NSString *) debugBreakOnChange:(NSString *) keyPath line:(int) lineNum file:(const char *) filePath
		func:(const char *) func
{
	if (!AmIBeingDebugged())
		return @"No debugger detected or not debug build; debugBreakOnChange called but will not fire.";
		
	__block EBNObservation *ob = [[EBNObservation alloc] initForObserved:self observer:self immedBlock:
			^(EBNObservable *blockSelf, EBNObservable *observed, id previousValue)
			{
				id newValue = [observed valueForKeyPath:keyPath];
				if (!(newValue == previousValue) && ![newValue isEqual:previousValue])
				{
					EBLogStdOut(@"debugBreakOnChange breakpoint on keyPath: %@", keyPath);
					EBLogStdOut(@"    debugString: %@", ob.debugString);
					EBLogStdOut(@"    prevValue: %@", previousValue);
					EBLogStdOut(@"    newValue: %@", newValue);
					
					// This line will cause a break in the debugger! If you stop here in the debugger, it is
					// because someone added a debugBreakOnChange: call somewhere, and its keypath just changed.
					DEBUG_BREAKPOINT;
				}
			}];
			
	if (lineNum > 0)
		[ob setDebugStringWithFn:func file:filePath line:lineNum];
	else
		ob.debugString = @"Set from debugger.";
	[ob observe:keyPath];
	
	return [NSString stringWithFormat:@"Will break in debugger when %@ changes.", keyPath];
}


/****************************************************************************************************
	debugShowAllObservers
	
	Shows all the observers of the given observed object.
*/
- (NSString *) debugShowAllObservers
{
	NSMutableString *debugStr = [NSMutableString stringWithFormat:@"\n%@\n", [self debugDescription]];
	for (NSString *observedMethod in self->_observedMethods)
	{
		[debugStr appendFormat:@"    %@ notifies:\n", observedMethod];
		NSMutableSet *keypathEntries = self->_observedMethods[observedMethod];
		for (EBNKeypathEntryInfo *entry in keypathEntries)
		{
			EBNObservation *blockInfo = entry->_blockInfo;
			id observer = blockInfo->_weakObserver;
			NSString *blockDebugStr = blockInfo.debugString;
			if (blockDebugStr)
			{
				[debugStr appendFormat:@"        %@", blockDebugStr];
			} else
			{
				[debugStr appendFormat:@"        %p: for <%s: %p> ",
						entry->_blockInfo, class_getName([observer class]), observer];
			}
			
			if ([entry->_keyPath count] > 1)
			{
				[debugStr appendFormat:@" path:"];
				NSString *separator = @"";
				for (NSString *prop in entry->_keyPath)
				{
					[debugStr appendFormat:@"%@%@", separator, prop];
					separator = @".";
				}
			}
			[debugStr appendFormat:@"\n"];
		}
	}
	[debugStr appendFormat:@"\n"];
	
	return debugStr;
}

/****************************************************************************************************
	debugDumpAllObservedMethods
	
	Dumps the all observed classes and all the methods that are being observed.
*/
+ (NSString *) debugDumpAllObservedMethods
{
	NSMutableString *dumpStr = [[NSMutableString alloc] initWithFormat:@"Observed Methods:\n"];
	
	for (Class baseClass in EBNBaseClassToShadowInfoTable)
	{
		EBNShadowedClassInfo *info = EBNBaseClassToShadowInfoTable[baseClass];
		[dumpStr appendFormat:@"    For class %@ with shadow class %@\n", baseClass, info->_shadowClass];
		
		for (NSString *propertyName in info->_getters)
		{
			[dumpStr appendFormat:@"        getter: %@\n", propertyName];
		}
		for (NSString *propertyName in info->_setters)
		{
			[dumpStr appendFormat:@"        setter: %@\n", propertyName];
		}
	}

	return dumpStr;
}

@end

/****************************************************************************************************
	EBNShadowed_ClassForCoder
	
	Lifted, more or less, from Mike Ash's MAZeroingWeakRef code, this makes classForCoder return
	the base class instead of our private runtime-created subclass.
*/
static Class EBNShadowed_ClassForCoder(id self, SEL _cmd)
{
	Class shadowClass = object_getClass(self);
	@synchronized(EBNBaseClassToShadowInfoTable)
	{
		while (shadowClass && shadowClass != [EBNObservable class] && !EBNShadowedClassToInfoTable[shadowClass])
		{
			shadowClass = class_getSuperclass(shadowClass);
		}
	}

    Class superclass = class_getSuperclass(shadowClass);
    IMP superClassForCoder = class_getMethodImplementation(superclass, @selector(classForCoder));
    Class classForCoder = ((id (*)(id, SEL))superClassForCoder)(self, _cmd);
    if (classForCoder == shadowClass)
        classForCoder = superclass;
    return classForCoder;
}


#pragma mark -
#pragma mark Template Methods

// Comparison methods for overrideSetterMethod(). General case and specializations.
// These are used in the overrideSetterMethod template function, as a way
// to give that function a generalized comparison capability.
template<typename T> struct SetterValueCompare
{
	static inline bool isEqual(const T a, const T b)
	{
		return a == b;
	};
};

template<> struct SetterValueCompare <CGPoint>
{
	static inline bool isEqual(const CGPoint a, const CGPoint b) 
	{
		return a.x == b.x && a.y == b.y;
	}
};

template<> struct SetterValueCompare <NSRange>
{
	static inline bool isEqual(const NSRange a, const NSRange b)
	{
		return a.location == b.location && a.length == b.length;
	}
};

template<> struct SetterValueCompare <CGSize>
{
	static inline bool isEqual(const CGSize a, const CGSize b)
	{
		return a.width == b.width && a.height == b.height;
	}
};

template<> struct SetterValueCompare <CGRect>
{
	static inline bool isEqual(const CGRect a, const CGRect b)
	{
		return a.origin.x == b.origin.x && a.origin.y == b.origin.y &&
				a.size.width == b.size.width && a.size.height == b.size.height;
	}
};

// If someone is is observing a keypath "a.b.c.d" and object "[b setC]" gets called, property "c"
// of object b will get a new value, meaning that we need to update our observations on object "c",
// removing observation on the old object and adding it to the new (unless either of them is nil).
// All of this keypath craziness only happens for properties of type id, so this template specialization
// makes that happen. That's why the general template case does nothing.
template<typename T> struct SetterKeypathUpdate
{
	static inline void updateKeypath(const EBNKeypathEntryInfo * const entry, const NSMapTable * const observerTable,
			const T previousValue, const T newValue) {}
};

template<> struct SetterKeypathUpdate <id>
{
	static inline void updateKeypath(const EBNKeypathEntryInfo * const entry, const NSMapTable * const observerTable,
			const id previousValue, const id newValue)
	{
		NSInteger index = [[observerTable objectForKey:entry] integerValue];
		if (index != [entry->_keyPath count] - 1)
		{
			[previousValue removeKeypath:entry atIndex:index + 1];
			[newValue createKeypath:entry atIndex:index + 1];
		}

	}
};

// All this because I didn't want to call valueForKey: before we knew whether there were immediate
// mode blocks to be called or not.
static inline id EBNWrapValue(const bool value) 			{ return [NSNumber numberWithBool:value]; }
static inline id EBNWrapValue(const char value) 			{ return [NSNumber numberWithChar:value]; }
static inline id EBNWrapValue(const double value) 			{ return [NSNumber numberWithDouble:value]; }
static inline id EBNWrapValue(const float value) 			{ return [NSNumber numberWithFloat:value]; }
static inline id EBNWrapValue(const int value) 				{ return [NSNumber numberWithInt:value]; }
static inline id EBNWrapValue(const long value) 			{ return [NSNumber numberWithLong:value]; }
static inline id EBNWrapValue(const long long value) 		{ return [NSNumber numberWithLongLong:value]; }
static inline id EBNWrapValue(const short value) 			{ return [NSNumber numberWithShort:value]; }
static inline id EBNWrapValue(const unsigned char value) 	{ return [NSNumber numberWithUnsignedChar:value]; }
static inline id EBNWrapValue(const unsigned int value) 	{ return [NSNumber numberWithUnsignedInt:value]; }
static inline id EBNWrapValue(const unsigned long value) 	{ return [NSNumber numberWithUnsignedLong:value]; }
static inline id EBNWrapValue(const unsigned long long value) { return [NSNumber numberWithUnsignedLongLong:value]; }
static inline id EBNWrapValue(const unsigned short value) 	{ return [NSNumber numberWithUnsignedShort:value]; }
static inline id EBNWrapValue(const void * value) 			{ return [NSValue valueWithPointer:value]; }
static inline id EBNWrapValue(const id value) 				{ return value; }
static inline id EBNWrapValue(const NSRange value)			{ return [NSValue valueWithRange:value]; }
static inline id EBNWrapValue(const CGPoint value)			{ return [NSValue valueWithCGPoint:value]; }
static inline id EBNWrapValue(const CGRect value)			{ return [NSValue valueWithCGRect:value]; }
static inline id EBNWrapValue(const CGSize value)			{ return [NSValue valueWithCGSize:value]; }

/****************************************************************************************************
	template <T> overrideSetterMethod()
	
	Overrides the given setter method with a new method (actually a block with implementationWithBlock()
	used on it) that notifies observers after it's called.
*/
template<typename T> void overrideSetterMethod(NSString *propName,
		Method setter, Method getter, Class classToModify)
{
	// All of these local variables get copied into the setAndObserve block
	void (*originalSetter)(id, SEL, T) = (void (*)(id, SEL, T)) method_getImplementation(setter);
	SEL setterSEL = method_getName(setter);
	SEL getterSEL = method_getName(getter);
	
	bool doMarkPropertyValid = [classToModify instancesRespondToSelector:@selector(markPropertyValid:)];
	
	// This is what gets run when the setter method gets called.
	void (^setAndObserve)(EBNObservable *, T) = ^void (EBNObservable *blockSelf, T newValue)
	{
		if (doMarkPropertyValid)
			[blockSelf performSelector:@selector(markPropertyValid:) withObject:propName];
				
		T (*getterImplementation)(id, SEL) = (T (*)(id, SEL)) method_getImplementation(getter);
		T previousValue = getterImplementation(blockSelf, getterSEL);
		(originalSetter)(blockSelf, setterSEL, newValue);
		
		// If the value actually changes do all the observation stuff
		if (!SetterValueCompare<T>::isEqual(previousValue, newValue))
		{
			bool reapAfterIterating = false;
			
			@synchronized(EBNObservableSynchronizationToken)
			{
				NSMapTable *observerTable = [blockSelf->_observedMethods[propName] copy];
				for (EBNKeypathEntryInfo *entry in observerTable)
				{
					// Only the object specialization actually implements this
					// (only objects can have properties, ergo everyone else is a keypath endpoint).
					SetterKeypathUpdate<T>::updateKeypath(entry, observerTable, previousValue, newValue);
	
					// If this is an immed block, wrap the previous value and call it.
					// Why not just call [blockSelf valueForKey:]? Immed blocks shouldn't be used much
					// and we'd have to call valueForKey before setting the new value.
					EBNObservation *blockInfo = entry->_blockInfo;
					if (blockInfo->_copiedImmedBlock)
						[blockInfo executeWithPreviousValue:EBNWrapValue(previousValue)];
		
					if (blockInfo->_copiedBlock)
					{
						EBNObservable *strongObserved = blockInfo->_weakObserved;
						if (strongObserved)
						{
							[EBN_ObserverBlocksToRunAfterThisEvent addObject:blockInfo];
							[EBN_ObservedObjectKeepAlive addObject:strongObserved];
						}
						else
						{
							reapAfterIterating = true;
						}
					}
				}
			}

			if (reapAfterIterating)
				[blockSelf reapBlocks];
		}
	};

	// Now replace the setter's implementation with the new one
	IMP swizzledImplementation = imp_implementationWithBlock(setAndObserve);
	class_replaceMethod(classToModify, setterSEL, swizzledImplementation, method_getTypeEncoding(setter));
}

/****************************************************************************************************
	EBN_RunLoopObserverCallBack()
	
	This method is a CFRunLoopObserver, scheduled with kCFRunLoopBeforeWaiting, so it fires just before
	the run loop idles.
	
	Calls all the observer blocks that got scheduled during the current runloop.
*/
void EBN_RunLoopObserverCallBack(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
	if (![EBN_ObserverBlocksToRunAfterThisEvent count])
		return;
		
	// This sync is important. It makes sure any set that happens in another thread blocks while
	// the main thread is draining the queue. This in turn means that a setter that gets called
	// in this block is being set from within an observer block.
	@synchronized(EBNObservableSynchronizationToken)
	{
		// This bit's important too. Each time through this loop we call a bunch of observer blocks.
		// But, observers could set properties, creating more observation blocks. We should call those
		// observers too, unless it will cause recursion. The idea is the masterCallList tracks
		// every block we've called during this event, and we only call any particular block once.
		NSMutableSet *masterCallList = [NSMutableSet set];
		
		while ([EBN_ObserverBlocksToRunAfterThisEvent count])
		{
			// Step 1: Copy the list of objects that have blocks that need to be called
			NSMutableSet *thisIterationCallList = [EBN_ObserverBlocksToRunAfterThisEvent copy];
			
			// Step 2: Call each observation block
			for (EBNObservation *blockInfo in thisIterationCallList)
			{
				[blockInfo execute];
			}

			// Step 3: Add the blocks we just called to the master list
			[masterCallList unionSet:thisIterationCallList];
			
			// Step 4: Remove any blocks we've already called from the global set
			[EBN_ObserverBlocksToRunAfterThisEvent minusSet:masterCallList];
		}
		
		// We're done notifying observers, purge the retains we've been keeping
		[EBN_ObservedObjectKeepAlive removeAllObjects];
	}
}

/****************************************************************************************************
	AmIBeingDebugged()
	
	AmIBeingDebugged calls sysctl() to see if a debugger is attached. Sample code courtesy Apple:
		https://developer.apple.com/library/mac/qa/qa1361/_index.html

	Because the struct kinfo_proc is marked unstable by Apple, we only use this code for Debug builds.
	That means this method will return FALSE on release builds, even if a debugger *is* attached.
*/
bool AmIBeingDebugged (void)
{
#if defined(DEBUG) && DEBUG
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid () };
	struct kinfo_proc info = { 0 };
	size_t size = sizeof (info);
	sysctl (mib, sizeof (mib) / sizeof (*mib), &info, &size, NULL, 0);

	// We're being debugged if the P_TRACED flag is set.
	return (info.kp_proc.p_flag & P_TRACED) != 0;
#else
	return false;
#endif
}



