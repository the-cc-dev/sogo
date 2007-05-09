/* LDAPUserManager.m - this file is part of SOGo
 *
 * Copyright (C) 2007 Inverse groupe conseil
 *
 * Author: Wolfgang Sourdeau <wsourdeau@inverse.ca>
 *
 * This file is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSUserDefaults.h>
#import <Foundation/NSValue.h>

#import "LDAPSource.h"
#import "LDAPUserManager.h"

static NSString *defaultMailDomain = nil;

@implementation LDAPUserManager

+ (void) initialize
{
  NSUserDefaults *ud;

  ud = [NSUserDefaults standardUserDefaults];
  if (!defaultMailDomain)
    {
      defaultMailDomain = [ud stringForKey: @"SOGoDefaultMailDomain"];
      [defaultMailDomain retain];
    }
}

+ (id) sharedUserManager
{
  static id sharedUserManager = nil;

  if (!sharedUserManager)
    sharedUserManager = [self new];

  return sharedUserManager;
}

- (void) _registerSource: (NSDictionary *) udSource
{
  NSMutableDictionary *metadata;
  LDAPSource *ldapSource;
  NSString *sourceID, *value;
  
  sourceID = [udSource objectForKey: @"id"];
  ldapSource = [LDAPSource sourceFromUDSource: udSource];
  [sources setObject: ldapSource forKey: sourceID];
  metadata = [NSMutableDictionary dictionary];
  value = [udSource objectForKey: @"canAuthenticate"];
  if (value)
    [metadata setObject: value forKey: @"canAuthenticate"];
  value = [udSource objectForKey: @"isAddressBook"];
  if (value)
    [metadata setObject: value forKey: @"isAddressBook"];
  value = [udSource objectForKey: @"displayName"];
  if (value)
    [metadata setObject: value forKey: @"displayName"];
  [sourcesMetadata setObject: metadata forKey: sourceID];
}

- (void) _prepareLDAPSourcesWithDefaults: (NSUserDefaults *) ud
{
  NSArray *udSources;
  unsigned int count, max;

  sources = [NSMutableDictionary new];
  sourcesMetadata = [NSMutableDictionary new];

  udSources = [ud arrayForKey: @"SOGoLDAPSources"];
  max = [udSources count];
  for (count = 0; count < max; count++)
    [self _registerSource: [udSources objectAtIndex: count]];
}

- (id) init
{
  NSUserDefaults *ud;

  if ((self = [super init]))
    {
      ud = [NSUserDefaults standardUserDefaults];

      sources = nil;
      sourcesMetadata = nil;
      users = [NSMutableDictionary new];
      cleanupInterval
	= [ud integerForKey: @"SOGOLDAPUserManagerCleanupInterval"];
      if (cleanupInterval)
	cleanupTimer = [NSTimer timerWithTimeInterval: cleanupInterval
				target: self
				selector: @selector (cleanupUsers)
				userInfo: nil
				repeats: YES];
      [self _prepareLDAPSourcesWithDefaults: ud];
    }

  return self;
}

- (void) dealloc
{
  [sources release];
  [users release];
  [super dealloc];
}

- (NSArray *) sourceIDs
{
  return [sources allKeys];
}

- (NSArray *) _sourcesOfType: (NSString *) sourceType
{
  NSMutableArray *sourceIDs;
  NSEnumerator *allIDs;
  NSString *currentID;
  NSNumber *canAuthenticate;

  sourceIDs = [NSMutableArray array];
  allIDs = [[sources allKeys] objectEnumerator];
  currentID = [allIDs nextObject];
  while (currentID)
    {
      canAuthenticate = [[sourcesMetadata objectForKey: currentID]
			  objectForKey: sourceType];
      if ([canAuthenticate boolValue])
	[sourceIDs addObject: currentID];
      currentID = [allIDs nextObject];
    }

  return sourceIDs;
}

- (NSArray *) authenticationSourceIDs
{
  return [self _sourcesOfType: @"canAuthenticate"];
}

- (NSArray *) addressBookSourceIDs
{
  return [self _sourcesOfType: @"isAddressBook"];
}

- (LDAPSource *) sourceWithID: (NSString *) sourceID
{
  return [sources objectForKey: sourceID];
}

- (NSString *) displayNameForSourceWithID: (NSString *) sourceID
{
  NSDictionary *metadata;

  metadata = [sourcesMetadata objectForKey: sourceID];

  return [metadata objectForKey: @"displayName"];
}

- (NSString *) getCNForUID: (NSString *) uid
{
  NSDictionary *contactInfos;

  contactInfos = [self contactInfosForUserWithUIDorEmail: uid];

  return [contactInfos objectForKey: @"cn"];
}

- (NSString *) getEmailForUID: (NSString *) uid
{
  NSDictionary *contactInfos;

  contactInfos = [self contactInfosForUserWithUIDorEmail: uid];

  return [contactInfos objectForKey: @"c_email"];
}

- (NSString *) getUIDForEmail: (NSString *) email
{
  NSDictionary *contactInfos;

  contactInfos = [self contactInfosForUserWithUIDorEmail: email];

  return [contactInfos objectForKey: @"c_uid"];
}

- (BOOL) _ldapCheckLogin: (NSString *) login
	     andPassword: (NSString *) password
{ 
  BOOL checkOK;
  LDAPSource *ldapSource;
  NSEnumerator *authIDs;
  NSString *currentID;

  checkOK = NO;

  authIDs = [[self authenticationSourceIDs] objectEnumerator];
  currentID = [authIDs nextObject];
  while (currentID && !checkOK)
    {
      ldapSource = [sources objectForKey: currentID];
      checkOK = [ldapSource checkLogin: login andPassword: password];
      if (!checkOK)
	currentID = [authIDs nextObject];
    }

  return checkOK;
}

- (BOOL) checkLogin: (NSString *) login
	andPassword: (NSString *) password
{
  BOOL checkOK;
  NSDate *cleanupDate;
  NSMutableDictionary *currentUser;
  NSString *dictPassword;

  currentUser = [users objectForKey: login];
  dictPassword = [currentUser objectForKey: @"password"];
  if (currentUser && dictPassword)
    checkOK = ([dictPassword isEqualToString: password]);
  else if ([self _ldapCheckLogin: login andPassword: password])
    {
      checkOK = YES;
      if (!currentUser)
	{
	  currentUser = [NSMutableDictionary dictionary];
	  [users setObject: currentUser forKey: login];
	}
      [currentUser setObject: password forKey: @"password"];
    }
  else
    checkOK = NO;

  if (cleanupInterval)
    {
      cleanupDate = [[NSDate date] addTimeInterval: cleanupInterval];
      [currentUser setObject: cleanupDate forKey: @"cleanupDate"];
    }

  return checkOK;
}

- (void) _fillContactMailRecords: (NSMutableDictionary *) contact
{
  NSMutableArray *emails;
  NSString *uid;

  emails = [contact objectForKey: @"emails"];
  uid = [contact objectForKey: @"c_uid"];
  [emails addObject:
	    [NSString stringWithFormat: @"%@@%@", uid, defaultMailDomain]];
  [contact setObject: [emails objectAtIndex: 0] forKey: @"c_email"];
}

- (void) _fillContactInfosForUser: (NSMutableDictionary *) currentUser
		   withUIDorEmail: (NSString *) uid
{
  NSMutableArray *emails;
  NSDictionary *userEntry;
  NSEnumerator *ldapSources;
  LDAPSource *currentSource;
  NSString *cn, *email, *c_uid;

  emails = [NSMutableArray array];
  cn = nil;
  c_uid = nil;

  ldapSources = [sources objectEnumerator];
  currentSource = [ldapSources nextObject];
  while (currentSource)
    {
      userEntry = [currentSource lookupContactEntryWithUIDorEmail: uid];
      if (userEntry)
	{
	  if (!cn)
	    cn = [userEntry objectForKey: @"c_cn"];
	  if (!c_uid)
	    c_uid = [userEntry objectForKey: @"c_uid"];
	  email = [userEntry objectForKey: @"mail"];
	  if (email && ![emails containsObject: email])
	    [emails addObject: email];
	  email = [userEntry objectForKey: @"mozillaSecondEmail"];
	  if (email && ![emails containsObject: email])
	    [emails addObject: email];
	  email = [userEntry objectForKey: @"xmozillasecondemail"];
	  if (email && ![emails containsObject: email])
	    [emails addObject: email];
	}
      currentSource = [ldapSources nextObject];
    }

  if (!cn)
    cn = @"";
  if (!c_uid)
    c_uid = @"";

  [currentUser setObject: emails forKey: @"emails"];
  [currentUser setObject: cn forKey: @"cn"];
  [currentUser setObject: c_uid forKey: @"c_uid"];
  [self _fillContactMailRecords: currentUser];
}

- (void) _retainUser: (NSDictionary *) newUser
{
  NSString *key;
  NSEnumerator *emails;

  key = [newUser objectForKey: @"c_uid"];
  if (key)
    [users setObject: newUser forKey: key];
  emails = [[newUser objectForKey: @"emails"] objectEnumerator];
  key = [emails nextObject];
  while (key)
    {
      [users setObject: newUser forKey: key];
      key = [emails nextObject];
    }
}

- (NSDictionary *) contactInfosForUserWithUIDorEmail: (NSString *) uid
{
  NSMutableDictionary *currentUser, *contactInfos;
  NSDate *cleanupDate;
  BOOL newUser;

  contactInfos = [NSMutableDictionary dictionary];
  currentUser = [users objectForKey: uid];
  if (!([currentUser objectForKey: @"emails"]
	&& [currentUser objectForKey: @"cn"]))
    {
      if (!currentUser)
	{
	  newUser = YES;
	  currentUser = [NSMutableDictionary dictionary];
	}
      else
	newUser = NO;
      [self _fillContactInfosForUser: currentUser
	    withUIDorEmail: uid];
      if (newUser)
	[self _retainUser: currentUser];
    }

  if (cleanupInterval)
    {
      cleanupDate = [[NSDate date] addTimeInterval: cleanupInterval];
      [currentUser setObject: cleanupDate forKey: @"cleanupDate"];
    }

  return currentUser;
}

- (void) _fillContactsMailRecords: (NSEnumerator *) contacts
{
  NSMutableDictionary *currentContact;

  currentContact = [contacts nextObject];
  while (currentContact)
    {
      [self _fillContactMailRecords: currentContact];
      currentContact = [contacts nextObject];
    }
}

- (NSArray *) _compactAndCompleteContacts: (NSEnumerator *) contacts
{
  NSMutableDictionary *compactContacts, *returnContact;
  NSDictionary *userEntry;
  NSArray *newContacts;
  NSMutableArray *emails;
  NSString *uid, *email;

  compactContacts = [NSMutableDictionary dictionary];
  userEntry = [contacts nextObject];
  while (userEntry)
    {
      uid = [userEntry objectForKey: @"c_uid"];
      returnContact = [compactContacts objectForKey: uid];
      if (!returnContact)
	{
	  returnContact = [NSMutableDictionary dictionary];
	  [returnContact setObject: uid forKey: @"c_uid"];
	  [compactContacts setObject: returnContact forKey: uid];
	}
      if (![[returnContact objectForKey: @"c_name"] length])
	[returnContact setObject: [userEntry objectForKey: @"c_name"]
		       forKey: @"c_name"];
      if (![[returnContact objectForKey: @"cn"] length])
	[returnContact setObject: [userEntry objectForKey: @"c_cn"]
		       forKey: @"cn"];
      emails = [returnContact objectForKey: @"emails"];
      if (!emails)
	{
	  emails = [NSMutableArray array];
	  [returnContact setObject: emails forKey: @"emails"];
	}
      email = [userEntry objectForKey: @"mail"];
      if (email && ![emails containsObject: email])
	[emails addObject: email];
      email = [userEntry objectForKey: @"mozillaSecondEmail"];
      if (email && ![emails containsObject: email])
	[emails addObject: email];
      email = [userEntry objectForKey: @"xmozillasecondemail"];
      if (email && ![emails containsObject: email])
	[emails addObject: email];

      userEntry = [contacts nextObject];
    }
  newContacts = [compactContacts allValues];
  [self _fillContactsMailRecords: [newContacts objectEnumerator]];

  return newContacts;
}

- (NSArray *) fetchContactsMatching: (NSString *) filter
{
  NSMutableArray *contacts;
  NSEnumerator *ldapSources;
  LDAPSource *currentSource;

  contacts = [NSMutableArray array];

  ldapSources = [sources objectEnumerator];
  currentSource = [ldapSources nextObject];
  while (currentSource)
    {
      [contacts addObjectsFromArray:
		  [currentSource fetchContactsMatching: filter]];
      currentSource = [ldapSources nextObject];
    }

  return [self _compactAndCompleteContacts: [contacts objectEnumerator]];
}

- (void) cleanupSources
{
  NSEnumerator *userIDs;
  NSString *currentID;
  NSDictionary *currentUser;
  NSDate *now;

  now = [NSDate date];
  userIDs = [[users allKeys] objectEnumerator];
  currentID = [userIDs nextObject];
  while (currentID)
    {
      currentUser = [users objectForKey: currentID];
      if ([now earlierDate:
		 [currentUser objectForKey: @"cleanupDate"]] == now)
	[users removeObjectForKey: currentID];
      currentID = [userIDs nextObject];
    }
}

@end
