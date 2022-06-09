public with sharing class TimeSheetController {

    @AuraEnabled
    public static String getTableRows(String year, String month){
        Map<Id, Timesheet__c> timesheetMap = getTimesheetMap(year, month);
        Map<Id, Timesheet_project__c> projectMap = getActiveProjectsSOQL();
        Map<Id, Timesheet_entry__c> entryMap = getActualEntries(timesheetMap.keySet(), projectMap.keySet());
        List<TableRow> tableRows = new List<TableRow>();

        for(Timesheet__c ts : timesheetMap.values()){ 

            TableRow tr = new TableRow(ts);

            for(Timesheet_project__c project : projectMap.values()){
                EntryByProject tempEntryByProject = null;
                for(Timesheet_entry__c entry : entryMap.values()){
                    if(entry.Timesheet_project__r.Id == project.Id && entry.Timesheet__r.Id == ts.Id){ 
                        tempEntryByProject = new EntryByProject(entry, ts, project);
                        break;
                    }
                }

                if(tempEntryByProject != null){ 
                    tr.entryList.add(tempEntryByProject);
                } else{
                    tr.entryList.add(new EntryByProject(ts, project));
                }
            }

            tableRows.add(tr);
        }
        
        return JSON.serialize(tableRows);
    }

    @AuraEnabled
    public static List<Timesheet_project__c> getActiveProjects(){
        return getActiveProjectsSOQL().values();
    }

    @AuraEnabled
    public static User getCurrentUser(){
        return [
            SELECT Overtime__c
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];
    }

    @AuraEnabled
    public static String saveChanges(String tableRows, String year, String month){
        
        try{
            User currentUser = getCurrentUser();
            List<Object> timesheetsAndEntries = (List<Object>) JSON.deserializeUntyped(tableRows);

            Map<Id, Timesheet__c> timesheetMap = getTimesheetMap(year, month);
            List<Timesheet__c> timesheetsToUpdate = new List<Timesheet__c>();
            List<Timesheet_entry__c> entrysToUpsert = new List<Timesheet_entry__c>();
            Decimal overtime = currentUser.Overtime__c;
            
            for(Object obj : timesheetsAndEntries){
                Map<String, Object> timesheetFields = (Map<String, Object>)obj; 
                Timesheet__c tsTemp = timesheetMap.get((Id)timesheetFields.get('timesheetId'));

                Object dayoff = String.valueOf(timesheetFields.get('dayoff'));
                tsTemp.Day_Off__c = Boolean.valueOf(dayoff);

                Object toil = String.valueOf(timesheetFields.get('toil'));
                tsTemp.TOIL__c = Boolean.valueOf(toil);

                tsTemp.Comment__c = String.valueOf(timesheetFields.get('comment'));

                if(!isDayOffOrToil(tsTemp)){
                    if(timesheetFields.get('timeIn') != null){
                        List<String> timeIn = String.valueOf(timesheetFields.get('timeIn')).split(':'); 
                        tsTemp.Start__c = Time.newInstance(Integer.valueOf(timeIn[0]), Integer.valueOf(timeIn[1]), 0, 0);
                    } else{
                        tsTemp.Start__c = null;
                    }
            
                    if(timesheetFields.get('timeOut') != null){
                        List<String> timeOut = String.valueOf(timesheetFields.get('timeOut')).split(':'); 
                        tsTemp.End__c = Time.newInstance(Integer.valueOf(timeOut[0]), Integer.valueOf(timeOut[1]), 0, 0);
                    } else{
                        tsTemp.End__c = null;
                    }

                    Object lunchBreak = String.valueOf(timesheetFields.get('lunchBreak'));
                    if(lunchBreak == '') lunchBreak = 0;
                    tsTemp.Lunch_break__c = Double.valueOf(lunchBreak);
                } else{
                    tsTemp.Start__c = null;
                    tsTemp.End__c = null;
                    tsTemp.Lunch_break__c = null;
                }
                
                tsTemp.Total__c = getTotal(tsTemp);

                currentUser.Overtime__c -= tsTemp.Overtime__c;
                if(tsTemp.TOIL__c){
                    tsTemp.Overtime__c = - tsTemp.Official_work_hours__c;
                } else if(isWorkingDay(tsTemp)){
                    if(isOvertimeCountable(tsTemp)){
                        tsTemp.Overtime__c = (tsTemp.Total__c - tsTemp.Official_work_hours__c);
                    } else{
                        tsTemp.Overtime__c = 0;
                    }
                } else if(!isWorkingDay(tsTemp)){
                
                    tsTemp.Overtime__c = tsTemp.Total__c;
                } 
                currentUser.Overtime__c += tsTemp.Overtime__c;

                timesheetsToUpdate.add(tsTemp);

                List<String> entryList = String.valueOf(timesheetFields.get('entryList')).split('}, ');
                entryList[0] = entryList[0].removeStart('({');
                entryList[entryList.size() - 1] = entryList[entryList.size() - 1].removeEnd('})');

                for(String entry : entryList){
                    entry = entry.removeStart('{');

                    Timesheet_entry__c entryTemp = new Timesheet_entry__c();

                    List<String> fieldsWithValues = entry.split(', ');

                    for(String fieldWithVal : fieldsWithValues){
                        if(fieldWithVal != '()'){
                            List<String> fieldAndValue = fieldWithVal.split('=');
                            String field = fieldAndValue[0];
                            String value = fieldAndValue.size() == 1 ? null : fieldWithVal.split('=')[1];

                            if(field == 'concatenatedId'){
                                entryTemp.Timesheet__c = value.split('_')[0];
                                entryTemp.Timesheet_project__c = value.split('_')[1];
                            } else if(field == 'entryId' && value != 'null'){
                                entryTemp.Id = value;
                            } else if(field == 'hours' && value != 'null'){
                                if(!isDayOffOrToil(tsTemp) && value != null){
                                    entryTemp.Hours__c = Decimal.valueOf(value);
                                } else{
                                    entryTemp.Hours__c = null;
                                }
                            }
                        }
                    }

                    if(entryTemp.Id != null || entryTemp.Hours__c != null){
                        entrysToUpsert.add(entryTemp);
                    }
                }
            }

            update timesheetsToUpdate;
            upsert entrysToUpsert;
            update currentUser;

            return 'success';
        } catch(Exception ex){
            system.debug(ex.getMessage());
        }

        return 'error';
    }

    private static Decimal getTotal(Timesheet__c ts){
        if(ts.End__c != null && ts.Start__c != null){
            Decimal hoursWorked = 0;
            Decimal minutesWorked = 0;

            if(ts.Start__c.hour() != ts.End__c.hour()){
                hoursWorked = ts.End__c.hour() - ts.Start__c.hour();
            }

            if(ts.Start__c.minute() > 0){
                minutesWorked += (60 - ts.Start__c.minute());
                hoursWorked--;
            }
            minutesWorked += ts.End__c.minute();

            hoursWorked += (minutesWorked / 60);
            if(ts.Lunch_break__c != null){
                hoursWorked -= ts.Lunch_break__c;
            }

            return hoursWorked;
        }

        return 0;
    }

    private static Boolean isWorkingDay(Timesheet__c ts){
        return !ts.Weekend__c && !ts.Holiday__c && !ts.Day_off__c && !ts.TOIL__c;
    }

    private static Map<Id, Timesheet__c> getTimesheetMap(String year, String month){
        List<Date> allDates = DateUtility.getAllDaysInMonth(year, month);

        return getTimesheetMapSOQL(allDates);
    }

    private static Boolean isOvertimeCountable(Timesheet__c ts){
        return ts.Start__c != null && ts.End__c != null;
    }

    private static Boolean isDayOffOrToil(Timesheet__c ts){
        return ts.Day_off__c || ts.TOIL__c;
    }

    private static Map<Id, Timesheet_project__c> getActiveProjectsSOQL(){
        return new Map<Id, Timesheet_project__c>([
            SELECT Name, Project_Type__c
            FROM Timesheet_project__c
            WHERE Active__c = true
            ORDER BY Project_Type__c, Order__c ASC NULLS LAST
        ]);
    }

    private static Map<Id, Timesheet__c> getTimesheetMapSOQL(List<Date> datesInMonth){
        return new Map<Id, Timesheet__c>([
            SELECT Date__c, Day_Off__c, End__c,	Holiday__c, Lunch_break__c, Start__c, Total__c, User__c, Weekend__c, 
                Day_of_the_Week__c, TOIL__c, Overtime__c, Comment__c, Official_work_hours__c
            FROM Timesheet__c
            WHERE Date__c IN :datesInMonth AND User__c = :UserInfo.getUserId()
            ORDER BY Date__c
        ]);
    }

    private static Map<Id, Timesheet_entry__c> getActualEntries(Set<Id> timesheetIds, Set<Id> projectIds){
        return new Map<Id, Timesheet_entry__c>([
            SELECT Hours__c, Timesheet__c, Timesheet_project__c, Timesheet_project__r.Name, Timesheet__r.Id
            FROM Timesheet_entry__c
            WHERE Timesheet__c IN :timesheetIds AND Timesheet_project__c IN :projectIds
            ORDER BY Timesheet_project__r.Project_Type__c, Timesheet_project__r.Name
        ]);
    }

    private class TableRow{

        String timesheetId;
        Date dayDate;
        String dayOfWeek;
        Time timeIn;
        Time timeOut;
        Id userId;
        Decimal lunchBreak;
        Decimal total;
        Boolean weekend;
        Boolean holiday;
        Boolean dayoff;
        Boolean toil;
        Boolean isDayOffOrToil;
        Boolean isWeekend;
        String comment;
        Decimal officialWorkHours;
        Decimal overtime;
        List<EntryByProject> entryList;

        TableRow(Timesheet__c ts){
            this.timesheetId = ts.Id;
            this.dayDate = ts.Date__c;
            this.dayOfWeek = ts.Day_of_the_Week__c;
            this.timeIn = ts.Start__c;
            this.timeOut = ts.End__c;
            this.userId = ts.User__c;
            this.lunchBreak = ts.Lunch_break__c;
            this.total = ts.Total__c;
            this.weekend = ts.Weekend__c;
            this.holiday = ts.Holiday__c;
            this.dayoff = ts.Day_Off__c;
            this.toil = ts.Toil__c;
            this.isDayOffOrToil = isDayOffOrToil(ts);
            this.isWeekend = isWeekend(ts);
            this.comment = ts.Comment__c;
            this.officialWorkHours = ts.Official_work_hours__c;
            this.overtime = ts.Overtime__c;
            this.entryList = new List<EntryByProject>();
        }

        private Boolean isDayOffOrToil(Timesheet__c ts){
            return ts.Day_off__c || ts.TOIL__c;
        }

        private Boolean isWeekend(Timesheet__c ts){
            return ts.Weekend__c || ts.Holiday__c;
        }
    }

    private class EntryByProject{

        String entryId;
        String projectName;
        String concatenatedId;
        Decimal hours;

        EntryByProject(Timesheet_entry__c entry, Timesheet__c ts, Timesheet_project__c tp){
            this.entryId = entry.Id;
            this.projectName = entry.Timesheet_project__r.Name;
            this.concatenatedId = getConcatenatedId(ts, tp);
            this.hours = entry.Hours__c;
        }

        EntryByProject(Timesheet__c ts, Timesheet_project__c tp){
            this.projectName = tp.Name;
            this.concatenatedId = getConcatenatedId(ts, tp);
        }

        private String getConcatenatedId(Timesheet__c ts, Timesheet_project__c tp){
            return ts.Id + '_' + tp.Id;
        }
    }
}